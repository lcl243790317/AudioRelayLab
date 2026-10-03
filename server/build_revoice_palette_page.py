# SPDX-License-Identifier: GPL-3.0-only
"""Build an offline, multi-selection listening page for the expanded voice auditions."""
import argparse
import array
import base64
import hashlib
import json
import math
import sys
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def read_clip(folder, sample):
    path = folder / (sample['id'] + '.wav')
    data = path.read_bytes()
    report = json.loads(path.with_suffix('.json').read_text(encoding='utf-8'))
    if hashlib.sha256(data).hexdigest() != report['sha256']:
        raise ValueError('Audio hash mismatch: ' + path.name)
    if report['text'] != sample['text'] or report['sourceAudioProvidedToSynthesis'] or report['sourceTimingProvided']:
        raise ValueError('Auditions must synthesize the exact text without source voice features')
    with wave.open(str(path), 'rb') as audio:
        if audio.getsampwidth() != 2 or audio.getnchannels() != 1:
            raise ValueError('Expected the original mono PCM16 output')
        rate = audio.getframerate()
        duration = audio.getnframes() / rate
        values = array.array('h', audio.readframes(audio.getnframes()))
        if sys.byteorder != 'little':
            values.byteswap()
    if abs(duration - report['outputDuration']) > 1 / rate:
        raise ValueError('Actual audio duration disagrees with its metadata')
    # Compare speaking loudness without allowing long pauses to bias the result.
    window = max(1, rate // 50)
    energies = [sum(v * v for v in values[i:i + window]) / len(values[i:i + window])
                for i in range(0, len(values), window)]
    active = [energy for energy in energies if energy > max(energies) * .01]
    rms = math.sqrt(sum(active) / len(active)) / 32768
    return dict(id=sample['id'], scene=sample.get('scene'), text=sample['text'], duration=duration,
                seconds=report['elapsedSeconds'], rms=rms, sha256=report['sha256'],
                audio='data:audio/wav;base64,' + base64.b64encode(data).decode())


def make_page(audio_dir, output):
    folder = Path(audio_dir).resolve()
    manifest = json.loads((folder / 'audition-manifest.json').read_text(encoding='utf-8'))
    profiles = []
    for profile in manifest['profiles']:
        item = {key: profile[key] for key in ('id', 'label', 'group', 'kind', 'description')}
        item['accepted'] = profile['id'] in manifest['accepted']
        item['clips'] = [read_clip(folder, sample) for sample in profile['samples']]
        if profile['kind'] == 'designed':
            item['reference'] = read_clip(folder, dict(id=profile['referenceID'], text=manifest['referenceText']))
            reference_hash = item['reference']['sha256']
            for sample in profile['samples']:
                report = json.loads((folder / (sample['id'] + '.json')).read_text(encoding='utf-8'))
                if report['targetReferenceSHA256'] != reference_hash:
                    raise ValueError('All utterances of a designed voice must share its fixed reference')
        profiles.append(item)
    # Only attenuate; the embedded WAV files remain byte-for-byte unchanged.
    common_rms = min(clip['rms'] for profile in profiles for clip in profile['clips'])
    for profile in profiles:
        for clip in profile['clips'] + ([profile['reference']] if 'reference' in profile else []):
            clip['matchedVolume'] = min(1, common_rms / clip.pop('rms'))
    dataset = dict(round=manifest['round'], cases=manifest['cases'], profiles=profiles)
    serialized = json.dumps(dataset, ensure_ascii=False).replace('<', '\\u003c')
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(PAGE.replace('__DATASET__', serialized), encoding='utf-8')
    print('Built offline page:', output, 'voices:', len(profiles), 'clips:',
          sum(len(p['clips']) + ('reference' in p) for p in profiles), 'bytes:', output.stat().st_size, flush=True)


PAGE = '''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>声线扩展试听 · AudioRelayLab</title>
<style>
:root{color-scheme:light;--ink:#273b35;--muted:#62736b;--green:#36664f;--line:#d8e0d6;--paper:#fffcf5}*{box-sizing:border-box}body{margin:0;background:#eff3ed;color:var(--ink);font:16px/1.6 system-ui,-apple-system,"Microsoft YaHei",sans-serif}main{max-width:1100px;margin:32px auto;padding:0 22px}.eyebrow{color:var(--green);font-size:12px;letter-spacing:2px}h1{font-size:34px;line-height:1.2;margin:10px 0 14px}h2{font-size:20px;line-height:1.4;margin:0 0 12px}p{margin:8px 0}.muted{font-size:14px;color:var(--muted)}.card{background:var(--paper);border:1px solid var(--line);border-radius:16px;padding:24px;margin:18px 0}.filters,.scenes,.metrics,.ratings{display:flex;gap:8px;flex-wrap:wrap}.filters{margin:16px 0}.voices{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}.layout{display:grid;grid-template-columns:380px minmax(0,1fr);gap:22px}.voice{text-align:left;padding:11px 13px}.voice strong{display:block;font-size:15px}.voice small{display:block;font-size:12px;opacity:.8;margin-top:3px}.voice .badge{display:inline-block;font-size:11px;margin-top:5px;padding:0 6px;border:1px solid currentColor;border-radius:5px}button,input,textarea{font:inherit}button{color:inherit;border:1px solid var(--line);border-radius:10px;padding:8px 13px;cursor:pointer;background:white}button[aria-pressed="true"],button.primary{background:var(--green);border-color:var(--green);color:white}button:focus-visible,textarea:focus-visible,input:focus-visible{outline:3px solid #a5be76;outline-offset:3px}button:disabled{cursor:default;opacity:.45}.scenes button,.filters button,.ratings button{font-size:14px}.scenes{margin-bottom:15px}.metrics{margin:12px 0}.metrics span{font-size:13px;background:#edf0e7;padding:4px 9px;border-radius:6px}audio{width:100%;margin:10px 0 0}.script{background:#edf2e9;border-radius:10px;padding:16px;white-space:pre-wrap;overflow-wrap:anywhere}.toggle{display:flex;align-items:center;gap:8px;font-size:14px;margin:10px 0}.toggle input{width:16px;height:16px;accent-color:var(--green)}label{display:block;margin:12px 0 6px;font-size:14px}textarea{width:100%;min-height:90px;resize:vertical;padding:12px;background:white;color:inherit;border:1px solid var(--line);border-radius:10px}.feedback{border-top:1px solid var(--line);margin-top:20px;padding-top:18px}.feedback h2{font-size:17px}.export{display:flex;gap:15px;align-items:center;flex-wrap:wrap}.export p{margin:0}.reference{margin-top:15px}.reference summary,details.card summary{cursor:pointer;font-size:14px}#playStatus{min-height:22px;margin:8px 0}#savedStatus{min-height:22px}.foot{font-size:13px;color:var(--muted);margin:22px 0 35px} @media(max-width:900px){.layout{grid-template-columns:300px minmax(0,1fr)}} @media(max-width:700px){main{margin-top:22px;padding:0 14px}h1{font-size:28px}.card{padding:18px}.layout{grid-template-columns:minmax(0,1fr)}.voice{padding:10px}.voice strong{font-size:14px}.filters button,.scenes button{padding:7px 10px}.export{gap:10px}}
</style></head><body><main>
<header><div class="eyebrow">AUDIO RELAY LAB · 第二轮重新配音</div><h1>声线扩展试听</h1><p>保留你认可的 Serena、Vivian 原版，再试听 8 组新候选。</p><p class="muted">先用同一句话比较音色，再听角色台词。喜欢的可以都保留；本轮只做试听，App 仍为 1.5.1。</p></header>
<section class="card"><h2>挑一组声线</h2><div id="filters" class="filters" aria-label="声线分类"></div><div class="layout"><div><div id="voices" class="voices" aria-label="试听声线"></div><p class="muted">“原版”直接沿用你已认可的音频。“演绎”使用同一官方声线调整语气；“新设计”用固定参考复用声线。</p></div>
<div><div id="scenes" class="scenes" aria-label="试听文字"></div><h2 id="voiceTitle"></h2><p id="description" class="muted"></p><div id="metrics" class="metrics"></div><audio id="player" controls preload="metadata"></audio><p id="playStatus" class="muted" aria-live="polite"></p><label class="toggle"><input type="checkbox" id="matchVolume">统一试听音量</label><p class="muted" id="volumeNote">当前使用原始音量。统一音量只调整播放器，不修改原音频。</p><label for="script">这段配音使用的文字</label><div id="script" class="script"></div><p id="sceneNote" class="muted"></p>
<details id="reference" class="reference" hidden><summary>听这组新设计声线的固定参考</summary><audio id="referencePlayer" controls preload="metadata"></audio><div id="referenceMetrics" class="metrics"></div><p id="referenceText" class="muted"></p></details>
<div class="feedback"><h2 id="ratingTitle"></h2><div id="ratings" class="ratings" aria-label="当前声线评价"></div><label for="notes">记录这组的听感</label><textarea id="notes" placeholder="例如：音色喜欢，数字咬字还需要调；语气自然，但长句有夹嗓……"></textarea><p id="savedStatus" class="muted" aria-live="polite"></p></div></div></div></section>
<section class="card export"><button id="download" class="primary">导出全部试听反馈</button><div><p id="summary"></p><p class="muted">每组单独记录，可以保留多组；反馈仅保存在本机浏览器。</p></div></section>
<details class="card"><summary>本轮样本与验证方式</summary><p>10 组声线各有三段相同文字。8 组新候选另有角色台词；3 组新设计声线另有固定参考，共 41 段音频。上一组普通设计女声已从本轮移除。</p><p>所有新样本使用本地 Qwen3-TTS 1.7B。设计声线先生成固定参考，再由 Base 模型复用到四句话。语速、停顿与时长由目标声线决定，配音不接收你的原声、音高或原时长。</p><p>音频全部内嵌，离线可听。显示的模型耗时不含加载及识别；每段 WAV 的实际时长、文件哈希和固定参考哈希已核对。风格名称是候选目标，听起来是否合适由你判断。</p></details>
<p class="foot">请重点听自然感、夹嗓、咬字、年龄感和多句话的声线一致性。试听落实后，再接入 App。</p>
</main><script>
const dataset=__DATASET__;
const profiles=dataset.profiles,cases=dataset.cases,key='AudioRelayLab.revoice.expanded.v1';
const player=document.getElementById('player'),referencePlayer=document.getElementById('referencePlayer'),notes=document.getElementById('notes'),matchVolume=document.getElementById('matchVolume');
let selected=profiles[0].id,scene=cases[0].id,group='全部',ratings={},savingAvailable=true;
const choices=[['unreviewed','未评'],['keep','保留'],['adjust','再调'],['reject','不喜欢']];
for(const p of profiles)ratings[p.id]={decision:p.accepted?'keep':'unreviewed',notes:''};
try{const saved=JSON.parse(localStorage.getItem(key)||'{}');for(const p of profiles){const r=saved.profiles?.[p.id];if(r&&choices.some(c=>c[0]===r.decision))ratings[p.id]={decision:r.decision,notes:typeof r.notes==='string'?r.notes:''};}if(profiles.some(p=>p.id===saved.selected))selected=saved.selected;if([...cases.map(c=>c.id),'role'].includes(saved.scene))scene=saved.scene;matchVolume.checked=saved.matchVolume===true;}catch{savingAvailable=false;}
function current(){return profiles.find(p=>p.id===selected);}
function clip(){return current().clips.find(c=>c.scene===scene);}
function button(label,pressed,action){const b=document.createElement('button');b.textContent=label;b.setAttribute('aria-pressed',String(pressed));b.onclick=action;return b;}
function feedback(){return {round:dataset.round,date:new Date().toISOString(),selected,scene,matchVolume:matchVolume.checked,profiles:Object.fromEntries(profiles.map(p=>[p.id,{label:p.label,previouslyAccepted:p.accepted,...ratings[p.id]}]))};}
function save(){try{localStorage.setItem(key,JSON.stringify(feedback()));savingAvailable=true;}catch{savingAvailable=false;}document.getElementById('savedStatus').textContent=savingAvailable?'已保存在本机。':'浏览器未保存记录，请用下方按钮导出反馈。';}
function renderSummary(){const counts=choices.map(c=>[c[1],profiles.filter(p=>ratings[p.id].decision===c[0]).length]);document.getElementById('summary').textContent=counts.filter(c=>c[1]).map(c=>c[0]+' '+c[1]+' 组').join(' · ');}
function renderRatings(){const p=current();document.getElementById('ratingTitle').textContent='评价：'+p.label;document.getElementById('ratings').replaceChildren(...choices.map(c=>button(c[1],ratings[p.id].decision===c[0],()=>{ratings[p.id].decision=c[0];save();renderRatings();renderVoices();renderSummary();})));notes.value=ratings[p.id].notes;}
function renderVoices(){const visible=profiles.filter(p=>group==='全部'||p.group===group);document.getElementById('voices').replaceChildren(...visible.map(p=>{const b=button('',p.id===selected,()=>{selected=p.id;render();save();});b.dataset.voice=p.id;const title=document.createElement('strong');title.textContent=p.label;const source=document.createElement('small');source.textContent=p.kind==='accepted'?'已认可原版':p.kind==='custom'?'官方声线 · 风格演绎':'新设计 · 固定参考';const badge=document.createElement('span');badge.className='badge';badge.textContent=choices.find(c=>c[0]===ratings[p.id].decision)[1];b.className='voice';b.append(title,source,badge);return b;}));}
function applyVolume(){player.volume=matchVolume.checked?clip().matchedVolume:1;if(current().reference)referencePlayer.volume=matchVolume.checked?current().reference.matchedVolume:1;document.getElementById('volumeNote').textContent=matchVolume.checked?'已按说话段音量匹配，仅降低较响样本；原音频保留。':'当前使用原始音量。统一音量只调整播放器，不修改原音频。';}
function metrics(target,c){target.replaceChildren(...['音频时长 '+c.duration.toFixed(2)+' 秒','模型生成 '+c.seconds.toFixed(1)+' 秒'].map(t=>{const span=document.createElement('span');span.textContent=t;return span;}));}
function render(){const p=current();if(!p.clips.some(c=>c.scene===scene))scene=cases[0].id;const c=clip();const categories=['全部',...new Set(profiles.map(p=>p.group))];document.getElementById('filters').replaceChildren(...categories.map(category=>button(category,group===category,()=>{group=category;if(group!=='全部'&&current().group!==group)selected=profiles.find(p=>p.group===group).id;render();save();})));renderVoices();const scenes=cases.map(c=>({id:c.id,title:c.title}));if(p.kind!=='accepted')scenes.push({id:'role',title:'角色台词'});document.getElementById('scenes').replaceChildren(...scenes.map(s=>button(s.title,s.id===scene,()=>{scene=s.id;render();save();})));document.getElementById('voiceTitle').textContent=p.label;document.getElementById('description').textContent=p.description;metrics(document.getElementById('metrics'),c);document.getElementById('script').textContent=c.text;document.getElementById('sceneNote').textContent=scene==='role'?'角色台词按风格选择。同类候选可比较同一台词；跨风格比较请选上方三段共同文字。':'10 组使用完全相同的文字；切换从头播放，时长不对齐。';const wasPlaying=!player.paused;player.pause();referencePlayer.pause();player.src=c.audio;player.load();document.getElementById('playStatus').textContent='切换后从头播放。';const reference=document.getElementById('reference');reference.hidden=!p.reference;if(p.reference){referencePlayer.src=p.reference.audio;referencePlayer.load();metrics(document.getElementById('referenceMetrics'),p.reference);document.getElementById('referenceText').textContent=p.reference.text;}else{referencePlayer.removeAttribute('src');referencePlayer.load();reference.open=false;}applyVolume();renderRatings();renderSummary();document.getElementById('savedStatus').textContent=savingAvailable?'每组分别记录，切换后保留。':'浏览器未保存记录，请导出反馈。';if(wasPlaying)player.play().catch(()=>{document.getElementById('playStatus').textContent='请点击播放。';});}
player.addEventListener('play',()=>referencePlayer.pause());referencePlayer.addEventListener('play',()=>player.pause());
notes.oninput=()=>{ratings[selected].notes=notes.value;save();};matchVolume.onchange=()=>{applyVolume();save();};
document.getElementById('download').onclick=()=>{const url=URL.createObjectURL(new Blob([JSON.stringify(feedback(),null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download='revoice-expanded-listening-notes.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);};render();
</script></body></html>'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audio-dir', default=str(ROOT.parent / 'dist/revoice-expanded'))
    parser.add_argument('--output', default=str(ROOT.parent / 'dist/revoice-expanded/声线扩展试听.html'))
    args = parser.parse_args()
    make_page(args.audio_dir, args.output)


if __name__ == '__main__':
    main()
