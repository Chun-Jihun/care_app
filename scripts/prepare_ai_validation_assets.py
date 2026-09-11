"""Public, bounded VAD download only; never reads user media or starts inference."""
from scripts.ai_validation_common import DATA, EXPERIMENT, inventory, stamp, write_json

REVISION='be95df9152c0d7618fa1edfeb296fc3dae32376f'


def main():
    import requests
    directory=DATA/'sources/silero-vad-v6.2'
    directory.mkdir(parents=True,exist_ok=False)
    assets=[]
    for relative,limit in [('LICENSE',10000),('src/silero_vad/data/silero_vad.jit',5000000)]:
        url=f'https://raw.githubusercontent.com/snakers4/silero-vad/{REVISION}/{relative}'
        path=directory/relative.split('/')[-1]
        with requests.get(url,stream=True,timeout=60) as response:
            response.raise_for_status(); total=0
            with path.open('xb') as handle:
                for chunk in response.iter_content(65536):
                    total+=len(chunk)
                    if total>limit: raise ValueError('public asset exceeds fixed size cap')
                    handle.write(chunk)
        assets.append(dict(url=url,path=path.name,maximum_bytes=limit))
    write_json(EXPERIMENT/'vad-assets.lock.json',dict(repository='snakers4/silero-vad',
        tag='v6.2',revision=REVISION,license='MIT',directory=str(directory),files=inventory(directory),
        downloads=assets,downloaded_at=stamp(),evaluation_eligible=False))


if __name__=='__main__': main()
