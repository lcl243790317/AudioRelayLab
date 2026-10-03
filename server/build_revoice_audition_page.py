# SPDX-License-Identifier: GPL-3.0-only
"""Build a portable, offline listening page from verified local revoice evidence."""
import argparse
import base64
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parent

def make_page(audio_dir, output):
    root=Path(audio_dir).resolve()
    groups=[]
    def clip(name,label,description='',external=None):
        path=(root/(name+'.wav')) if external is None else Path(external).resolve()
        data=path.read_bytes()
        metadata_path=path.with_suffix('.json')
        metadata=json.loads(metadata_path.read_text(encoding='utf-8')) if metadata_path.exists() else {}
        if metadata.get('engine')=='Qwen3-TTS 1.7B':
            assert hashlib.sha256(data).hexdigest()==metadata['sha256']
            assert metadata['sourceAudioProvidedToSynthesis'] is False
        duration=metadata.get('outputDuration') or metadata.get('duration')
        if duration is None:
            import wave
            with wave.open(str(path),'rb') as wav:duration=wav.getnframes()/wav.getframerate()
        seconds=metadata.get('pipelineSeconds',metadata.get('elapsedSeconds'))
        return dict(id=name,label=label,description=description,duration=duration,seconds=seconds,
                    secondsLabel='完整流程' if 'pipelineSeconds' in metadata else '模型生成',
                    text=metadata.get('synthesisText',metadata.get('text','')),audio='data:audio/wav;base64,'+base64.b64encode(data).decode())
    cases=json.loads((ROOT/'revoice-audition-cases.json').read_text(encoding='utf-8-sig'))
    for case in cases['cases']:
        groups.append(dict(id=case['id'],title=case['title'],text=case['text'],note='三种声线说同一份文字；切换从头播放，不对齐时长。',
                           clips=[clip(prefix+'-'+case['id'],label) for prefix,label in [('serena','Serena'),('vivian','Vivian'),('designed','设计女声')]]))
    groups.append(dict(id='pipeline',title='真人录音 → 识别 → 重新配音',text=json.loads((root/'pipeline-male.json').read_text())['synthesisText'],
        note='原声与加快后的原声识别文字相同。两次独立配音都未收到原音频或原时长。',
        clips=[clip('source-male','原声 · 24秒'),clip('pipeline-male','Serena · 完整流程'),clip('source-male-fast','原声 · 节奏加快'),clip('pipeline-male-fast','Serena · 加快原声后的完整流程')]))
    groups.append(dict(id='dialogue',title='对白识别的错字示例',text=json.loads((root/'pipeline-dialogue.json').read_text())['synthesisText'],
        note='这段识别有人名、同音词疑点。下方展示未经改写的识别文字；配音会照着识别文字读。正式接入后可改字重做。',
        clips=[clip('source-dialogue','真人对白原声'),clip('pipeline-dialogue','Serena · 识别原文配音')]))
    groups.append(dict(id='long',title='短句与超过60秒的配音',text='',note='短句输入包含“嗯，嗯”，请听是否完整读出。长段按文字自然说完；60秒原声是重复拼接素材，仅验证长度。改字配音不再次识别。',
        clips=[clip('serena-short','短句 · Serena'),clip('serena-long','长段落 · Serena'),clip('pipeline-60s','60秒原声 → 自然重说'),clip('corrected-text','直接改字后配音')]))
    groups.append(dict(id='reference',title='设计声线的固定参考',text=cases['referenceText'],note='设计女声的三个对比样本复用这份固定参考；参考不是你的原录音。',
        clips=[clip('designed-reference','设计女声 · 固定参考')]))
    serialized=json.dumps(groups,ensure_ascii=False).replace('<','\\u003c')
    html=PAGE.replace('__RECORDINGS__',serialized)
    output=Path(output);output.parent.mkdir(parents=True,exist_ok=True);output.write_text(html,encoding='utf-8')
    print('Built offline page:',output,'clips:',sum(len(g['clips']) for g in groups),'bytes:',output.stat().st_size)

PAGE='''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>自然重新配音 · 试听</title>
<style>
:root{color-scheme:light;--ink:#273b35;--muted:#63766e;--accent:#36664f;--line:#d9e0d8;--paper:#fffcf5}*{box-sizing:border-box}body{margin:0;background:#f0f3ec;color:var(--ink);font:16px/1.6 system-ui,-apple-system,"Microsoft YaHei",sans-serif}main{max-width:940px;margin:36px auto;padding:0 20px}header{margin-bottom:25px}.eyebrow{font-size:13px;letter-spacing:2px;color:var(--accent)}h1{font-size:32px;line-height:1.25;margin:9px 0 12px}h2{font-size:19px;margin:0 0 15px}p{margin:8px 0}.muted{color:var(--muted);font-size:14px}.card{background:var(--paper);border:1px solid var(--line);border-radius:16px;padding:24px;margin:16px 0;box-shadow:0 5px 20px #26352805}.tabs,.voices{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:16px}button,select,textarea{font:inherit;color:inherit}button{border:1px solid var(--line);border-radius:10px;padding:9px 14px;cursor:pointer;background:white}button[aria-pressed="true"],button.primary{background:var(--accent);color:white;border-color:var(--accent)}button:focus-visible,select:focus-visible,textarea:focus-visible{outline:3px solid #a5be76;outline-offset:3px}audio{width:100%;margin:12px 0}.text{padding:16px;background:#eef2e9;border-radius:10px;white-space:pre-wrap;overflow-wrap:anywhere;font-size:16px}.metrics{display:flex;gap:8px;flex-wrap:wrap;margin:12px 0}.metrics span{background:#f0f0e8;padding:4px 10px;border-radius:6px;font-size:13px}label{display:block;font-size:14px;margin:14px 0 6px}select,textarea{width:100%;padding:10px 12px;background:white;border:1px solid var(--line);border-radius:9px}textarea{min-height:95px;resize:vertical}.foot{font-size:13px;color:var(--muted);margin:24px 0 40px}summary{cursor:pointer}#status{min-height:24px} @media(max-width:560px){main{margin-top:22px;padding:0 14px}h1{font-size:27px}.card{padding:18px}.tabs button,.voices button{padding:8px 11px;font-size:14px}}
</style></head><body><main>
<header><div class="eyebrow">AUDIO RELAY LAB · 新一轮试听</div><h1>这次，让目标声线重新说。</h1><p>只把文字交给配音模型。语调、停顿和时长由目标声线自然决定。</p><p class="muted">请先听“日常聊天”和“轻柔表达”，判断自然感、夹嗓与年龄感。三个候选尚未加入 App。</p></header>
<section class="card"><h2>选择一句话，再比较声线</h2><div class="tabs" id="groups" aria-label="试听内容"></div><p id="groupNote" class="muted"></p><div class="voices" id="clips" aria-label="声线或对比样本"></div><h2 id="currentTitle"></h2><div class="metrics" id="metrics"></div><audio id="player" controls preload="metadata"></audio><p id="status" class="muted" aria-live="polite"></p><label for="script">这段配音使用的文字</label><div id="script" class="text"></div></section>
<section class="card"><h2>你的听感决定是否接入</h2><p class="muted">不需要勉强挑一个。声音还不够自然，可以继续筛选。</p><label for="favorite">更喜欢哪一组？</label><select id="favorite"><option>未选择</option><option>Serena</option><option>Vivian</option><option>设计女声</option><option>这些都不满意</option></select><label for="notes">哪里自然，哪里还像 AI？</label><textarea id="notes" placeholder="例如：Serena 普通聊天不错，但长句像念稿；设计女声更合适……"></textarea><p><button class="primary" id="download">导出试听反馈</button></p><p class="muted">记录只保存在本机浏览器，不会上传音频或反馈。</p></section>
<details class="card"><summary>本轮验证范围</summary><p>Qwen3-TTS 1.7B，两个官方固定女声及一个固定参考的设计声线。每个生成样本都有模型版本、文件哈希、实际耗时与输出时长记录。</p><p>已单独测试 60 秒识别输入及超过 60 秒的文字配音输出。语音识别可能听错，配音也可能读错或漏字；文字检查不能替代你的试听。</p><p>页面全部音频内嵌，离线可用。正式 App 接入、取消队列和 1.6.0 构建在声线验收后完成。</p></details>
<p class="foot">初始候选不会因模型宣传或数值检查被判为“完美”。请反馈最自然的声线，或者直接选“这些都不满意”。</p>
</main><script>
const groups=__RECORDINGS__;
const player=document.getElementById('player');let groupIndex=0,clipIndex=0;
function button(label,selected,action){const b=document.createElement('button');b.textContent=label;b.setAttribute('aria-pressed',String(selected));b.onclick=action;return b;}
function render(){const group=groups[groupIndex],clip=group.clips[clipIndex];const list=document.getElementById('groups');list.replaceChildren(...groups.map((g,i)=>button(g.title,i===groupIndex,()=>{groupIndex=i;clipIndex=0;render();})));document.getElementById('groupNote').textContent=group.note;document.getElementById('clips').replaceChildren(...group.clips.map((c,i)=>button(c.label,i===clipIndex,()=>{clipIndex=i;render();})));document.getElementById('currentTitle').textContent=clip.label;document.getElementById('metrics').replaceChildren();const metrics=['音频时长 '+clip.duration.toFixed(2)+' 秒'];if(clip.seconds!=null)metrics.push(clip.secondsLabel+' '+clip.seconds.toFixed(1)+' 秒');for(const text of metrics){const s=document.createElement('span');s.textContent=text;document.getElementById('metrics').appendChild(s);}document.getElementById('script').textContent=clip.text||group.text||'这段是原声对照，配音文字请查看完整流程结果。';const wasPlaying=!player.paused;player.pause();player.src=clip.audio;player.load();document.getElementById('status').textContent='切换后从头播放；不同声线时长可不同。';if(wasPlaying)player.play().catch(()=>{document.getElementById('status').textContent='请点击播放，浏览器没有自动开始。';});}
const key='AudioRelayLab.revoice.listening.v1';const favorite=document.getElementById('favorite'),notes=document.getElementById('notes');try{const saved=JSON.parse(localStorage.getItem(key)||'{}');if(saved.favorite)favorite.value=saved.favorite;notes.value=saved.notes||'';}catch{}
function feedback(){return {favorite:favorite.value,notes:notes.value,selected:groups[groupIndex].clips[clipIndex].id,date:new Date().toISOString(),round:'text-only-revoice-1.7B'};}
function save(){try{localStorage.setItem(key,JSON.stringify(feedback()));}catch{}}
favorite.onchange=save;notes.oninput=save;document.getElementById('download').onclick=()=>{const blob=new Blob([JSON.stringify(feedback(),null,2)],{type:'application/json'});const url=URL.createObjectURL(blob);const a=document.createElement('a');a.href=url;a.download='revoice-listening-notes.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);};render();
</script></body></html>'''

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audio-dir',default=str(ROOT.parent/'dist/revoice'))
    parser.add_argument('--output',default=str(ROOT.parent/'dist/revoice/自然重新配音试听.html'))
    args=parser.parse_args();make_page(args.audio_dir,args.output)

if __name__=='__main__':main()
