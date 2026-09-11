"""Synthetic document detection and recognition, with explicit missed-row penalties."""
import argparse
import math
import os

from scripts.ai_validation_common import (DATA, EXPERIMENT, ROOT, aggregate_media, inputs,
    media_score, read_json, run, seal_inputs, sha256, verify_files, write_jsonl)


def iou(a,b):
    intersection=max(0,min(a[2],b[2])-max(a[0],b[0]))*max(0,min(a[3],b[3])-max(a[1],b[1]))
    union=(a[2]-a[0])*(a[3]-a[1])+(b[2]-b[0])*(b[3]-b[1])-intersection
    return intersection/union if union>0 else 0


def match_rows(expected,predicted,threshold=0.3):
    candidates=sorted([(iou(a,b),i,j) for i,a in enumerate(expected) for j,b in enumerate(predicted)],reverse=True)
    matches={}; used=set()
    for overlap,i,j in candidates:
        if overlap>=threshold and i not in matches and j not in used:
            matches[i]=j; used.add(j)
    return matches


def prepare():
    from PIL import Image
    source,rows,_=inputs('ocr'); directory=DATA/'inputs/ocr-pages'
    directory.mkdir(parents=True,exist_ok=False); pages=[]
    for language in ['ko','en','ja','zh-Hans','zh-Hant']:
        for variant in ['clean','rotate','blur','small','noise_contrast']:
            selected=[r for r in rows if r['language']==language and r['variant']==variant
                      and int(r['group_id'].rsplit('-',1)[1]) in [0,1,16,19]]
            images=[Image.open(source/r['path']).convert('RGB') for r in selected]
            page=Image.new('RGB',(max(im.width for im in images)+48,sum(im.height for im in images)+14*3+48),'white')
            y=24; labels=[]
            for row,img in zip(selected,images):
                page.paste(img,(24,y)); labels.append(dict(source_id=row['id'],reference=row['reference'],
                    negation_marker=row['negation_marker'],box=[24,y,24+img.width,y+img.height]))
                y+=img.height+14
            relative=f'images/{language}-{variant}.png'; path=directory/relative; path.parent.mkdir(exist_ok=True)
            page.save(path)
            pages.append(dict(id=f'FV-PAGE-{language}-{variant}',language=language,variant=variant,path=relative,rows=labels))
    write_jsonl(directory/'test.jsonl',pages)
    seal_inputs(directory,dict(task='ocr-pages',pages=25,rows=100,source_manifest_sha256=sha256(source/'manifest.json'),
        protocol_sha256=sha256(EXPERIMENT/'ocr-pages-protocol.md'),
        limitations='shared strings with line test; synthetic layout only; padded row rectangles as geometric gold'))


def crop_array(image,points):
    import cv2
    import numpy as np
    points=np.asarray(points,dtype='float32')
    width=max(2,round(max(np.linalg.norm(points[0]-points[1]),np.linalg.norm(points[2]-points[3]))))
    height=max(2,round(max(np.linalg.norm(points[0]-points[3]),np.linalg.norm(points[1]-points[2]))))
    destination=np.float32([[0,0],[width-1,0],[width-1,height-1],[0,height-1]])
    crop=cv2.warpPerspective(image,cv2.getPerspectiveTransform(points,destination),(width,height),borderMode=cv2.BORDER_REPLICATE)
    target_width=min(320,math.ceil(48*width/height))
    resized=cv2.resize(crop,(target_width,48)).astype('float32').transpose(2,0,1)/255
    padded=np.zeros((3,48,320),dtype='float32'); padded[:,:,:target_width]=(resized-0.5)/0.5
    return padded


def evaluate(args):
    os.environ.update(OMP_NUM_THREADS='2',MKL_NUM_THREADS='2')
    with run(args.run_id,vars(args)) as (directory,summary):
        # Windows: preload Torch DLLs before Paddle; ModelScope imports Torch later.
        import torch
        torch.set_num_threads(2)
        import cv2
        import numpy as np
        import paddle
        from paddleocr import TextDetection
        from scripts.run_ai_validation import ocr_model
        from scripts.run_ai_training_ocr import decode_ctc
        source,pages,_=inputs('ocr-pages'); paddle.set_device('cpu')
        summary.update(input_manifest_sha256=sha256(source/'manifest.json'),
                       pages_protocol_sha256=sha256(EXPERIMENT/'ocr-pages-protocol.md'))
        lock=read_json(ROOT/'experiments/ai_baseline_v1/assets.lock.json')['models']['ppocr5_det']
        model_path=ROOT/lock['local_path']; verify_files(model_path,lock['files'])
        detector=TextDetection(model_name='PP-OCRv5_mobile_det',model_dir=str(model_path),
            device='cpu',cpu_threads=2,enable_mkldnn=False,limit_side_len=960,limit_type='max',
            thresh=0.3,box_thresh=0.6,unclip_ratio=1.5)
        detections=[]; crops={}
        for page in pages:
            image=cv2.imread(str(source/page['path']))
            result=detector.predict(image)[0]
            polygons=np.asarray(result['dt_polys']).reshape(-1,4,2)
            boxes=[[float(p[:,0].min()),float(p[:,1].min()),float(p[:,0].max()),float(p[:,1].max())] for p in polygons]
            matches=match_rows([r['box'] for r in page['rows']],boxes)
            detections.append(dict(id=page['id'],language=page['language'],variant=page['variant'],
                expected=len(page['rows']),detected=len(boxes),matched=len(matches),
                missed=len(page['rows'])-len(matches),extra=len(boxes)-len(matches),
                polygons=polygons.tolist(),matches=matches))
            for i,j in matches.items(): crops[(page['id'],i)]=crop_array(image,polygons[j])
        detector.close()
        write_jsonl(directory/'detection.jsonl',detections)
        summary['detection']=dict(pages=len(pages),**{key:sum(r[key] for r in detections) for key in ['expected','detected','matched','missed','extra']})
        summary['detector_asset']=lock
        for kind,allowed in [('ko',{'ko','en'}),('multi',{'en','ja','zh-Hans','zh-Hant'})]:
            model,characters,checkpoint,assets=ocr_model(kind)
            selected=[p for p in pages if p['language'] in allowed]; features={}
            for page in selected:
                for i,_ in enumerate(page['rows']):
                    key=(page['id'],i)
                    if key in crops:
                        with paddle.no_grad(): features[key]=model.head.ctc_encoder(model.backbone(paddle.to_tensor(crops[key][None,:,:,:]))).detach()
            for arm in ['base','trained']:
                head=model.head.ctc_head
                if arm=='trained': head.set_state_dict(paddle.load(str(checkpoint)))
                head.eval(); predictions=[]
                for page in selected:
                    for i,row in enumerate(page['rows']):
                        key=(page['id'],i); text=''
                        if key in features:
                            with paddle.no_grad(): text=decode_ctc(head(features[key]).argmax(axis=-1).numpy()[0],characters)
                        predictions.append(dict(id=page['id']+'-'+str(i),language=page['language'],variant=page['variant'],
                            reference=row['reference'],text=text,detected=key in features,**media_score(row['reference'],text)))
                label=kind+'-'+arm; write_jsonl(directory/(label+'.jsonl'),predictions)
                summary[label]=aggregate_media(predictions)
            summary[kind+'-assets']=assets
        print(summary['detection'],flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('action',choices=['prepare','evaluate'])
    parser.add_argument('--run-id',default='ocr-pages-v1'); args=parser.parse_args()
    prepare() if args.action=='prepare' else evaluate(args)
