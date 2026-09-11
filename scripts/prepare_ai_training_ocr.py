"""Synthetic text-line supervision, separated by string group and font across splits."""
from pathlib import Path
import random

from scripts.ai_training_common import DATA, seal_inputs, sha256, write_jsonl

LANGS=['ko','en','ja','zh-Hans','zh-Hant']
FONTS={
 'ko':['malgun.ttf','malgunsl.ttf','malgunbd.ttf'],
 'en':['arial.ttf','ariali.ttf','arialbd.ttf'],
 'ja':['YuGothR.ttc','YuGothL.ttc','YuGothB.ttc'],
 'zh-Hans':['msyh.ttc','msyhl.ttc','msyhbd.ttc'],
 'zh-Hant':['msjh.ttc','msjhl.ttc','msjhbd.ttc']}
WORDS={
 'ko':['가상약','복용하지 않음','복용함','수분','걷기'],
 'en':['Test drug','Not taken','Taken','Water','Walk'],
 'ja':['架空薬','服用なし','服用済み','水分','歩行'],
 'zh-Hans':['虚构药','未服用','已服用','饮水','步行'],
 'zh-Hant':['虛構藥','未服用','已服用','飲水','步行']}


def main():
    from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageEnhance
    from fontTools.ttLib import TTFont
    directory=DATA/'inputs/ocr';directory.mkdir(parents=True,exist_ok=False)
    font_manifest=[];fingerprints={};counts={}
    for split_index,(split,count) in enumerate([('train',80),('validation',20),('test',40)]):
        rows=[]
        for lang in LANGS:
            path=Path('C:/Windows/Fonts')/FONTS[lang][split_index]
            with TTFont(path,fontNumber=0) as font: cmap=font.getBestCmap()
            font_manifest.append({'language':lang,'split':split,'path':str(path),'sha256':sha256(path),'redistributed':False})
            for i in range(count):
                serial=7000+1000*split_index+i
                words=WORDS[lang]
                texts=[f'{words[0]} X-{serial}',f'X{serial} {i%7}.5 mg',
                       f'X{serial} {words[1]}',f'X{serial} {words[2]}',
                       f'{words[3]} {100+i*5} mL X{serial}',f'{words[4]} {i%25+1} min X{serial}',
                       f'X{serial} 0.0{i%8+1} mg',f'X{serial} 08:{i%60:02}']
                reference=texts[i%8]
                if any(ord(c) not in cmap for c in reference):raise ValueError('missing font glyph')
                if reference in fingerprints and fingerprints[reference]!=split:raise ValueError('text split overlap')
                fingerprints[reference]=split
                variant=['clean','blur','low_contrast','small'][i%4]
                size=20 if variant=='small' else 30
                font=ImageFont.truetype(str(path),size)
                box=font.getbbox(reference);width=box[2]-box[0]+24;height=box[3]-box[1]+16
                image=Image.new('RGB',(width,height),'white')
                ImageDraw.Draw(image).text((12-box[0],8-box[1]),reference,fill='black',font=font)
                if variant=='blur':image=image.filter(ImageFilter.GaussianBlur(0.7))
                if variant=='low_contrast':image=ImageEnhance.Contrast(image).enhance(0.35)
                relative=f'images/{split}/{lang}-{i:03}.png'
                target=directory/relative;target.parent.mkdir(parents=True,exist_ok=True);image.save(target)
                rows.append({'id':f'FT-OCR-{split}-{lang}-{i:03}','split':split,'language':lang,
                    'group_id':f'{split}-line-{i}','path':relative,'reference':reference,'variant':variant,
                    'review_status':'compiler_generated_unreviewed','evaluation_eligible':False})
        random.Random(42+split_index).shuffle(rows)
        write_jsonl(directory/f'{split}.jsonl',rows);counts[split]=len(rows)
    seal_inputs(directory,{'task':'text_line_recognition','counts':counts,'fonts':font_manifest,
        'origin':'new project-generated nonpatient synthetic strings and raster images',
        'split_rule':'different line strings/IDs and font faces; shared semantic task templates',
        'limitations':'text-line/head adaptation only; not prescription layout, detector, handwriting or real photographs'})
    print('OCR frozen train400 validation100 test200',flush=True)


if __name__=='__main__':main()
