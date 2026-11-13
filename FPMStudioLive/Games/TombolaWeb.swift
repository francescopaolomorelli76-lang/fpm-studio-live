import Foundation

/// Pagina per i telefoni dei clienti: scelta della cartella (una per persona) e gioco a schermo intero.
/// I numeri usciti si segnano da soli; quando la cartella vince compare l'avviso da mostrare al banco.
enum TombolaWeb {
    static let html = #"""
<!doctype html><html lang="it"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes"><meta name="theme-color" content="#06140f">
<title>Tombola</title>
<style>
:root{--bg1:#06140f;--bg2:#2a0710;--gold:#ffd166;--red:#e63946;--green:#2a9d8f;--ink:#fff8ec;--soft:#e8d9bf}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;height:100%}
body{background:radial-gradient(120% 80% at 50% 0%,#12382c 0%,var(--bg1) 55%,var(--bg2) 100%) fixed;color:var(--ink);
 font-family:-apple-system,system-ui,"Segoe UI",Roboto,sans-serif;overflow-x:hidden;min-height:100%}
body.plain{background:linear-gradient(160deg,#070a1f,#160a2e) fixed}
#snow{position:fixed;inset:0;pointer-events:none;z-index:0}
.wrap{position:relative;z-index:1;max-width:760px;margin:0 auto;padding:max(12px,env(safe-area-inset-top)) 12px 24px}
header{display:flex;align-items:center;gap:10px;justify-content:center;margin-bottom:8px}
header img{height:42px;border-radius:8px}
header h1{margin:0;font-size:20px;letter-spacing:.04em;color:var(--gold);text-shadow:0 0 12px rgba(255,209,102,.5)}
header small{display:block;color:var(--soft);font-size:12px;font-weight:600;letter-spacing:.12em;text-transform:uppercase}
.lights{display:flex;justify-content:space-between;margin:0 -6px 6px;height:14px}
.lights i{width:10px;height:14px;border-radius:50% 50% 45% 45%;animation:blink 1.6s infinite}
.lights i:nth-child(4n+1){background:#ff4d6d}.lights i:nth-child(4n+2){background:#ffd166;animation-delay:.4s}
.lights i:nth-child(4n+3){background:#06d6a0;animation-delay:.8s}.lights i:nth-child(4n){background:#4cc9f0;animation-delay:1.2s}
@keyframes blink{50%{opacity:.25}}
.now{display:flex;align-items:center;gap:12px;background:rgba(255,255,255,.07);border:1px solid rgba(255,209,102,.35);
 border-radius:18px;padding:10px 14px;margin-bottom:10px}
.ball{flex:none;width:68px;height:68px;border-radius:50%;display:grid;place-items:center;font-size:32px;font-weight:900;color:#3b0a12;
 background:radial-gradient(circle at 35% 30%,#fff7d6,#ffd166 45%,#d4a017);box-shadow:0 0 22px rgba(255,209,102,.6)}
.ball.pop{animation:pop .7s ease}
@keyframes pop{0%{transform:scale(.3) rotate(-90deg)}70%{transform:scale(1.15)}100%{transform:scale(1)}}
.now .txt{min-width:0}
.now .nap{font-size:19px;font-weight:800;color:var(--gold)}
.now .it{font-size:14px;color:var(--soft)}
.now .sym{font-size:34px;margin-left:auto}
.bar{display:flex;justify-content:space-between;gap:8px;font-size:13px;color:var(--soft);margin:0 2px 10px;flex-wrap:wrap}
.bar b{color:var(--ink)}
.card{background:#fffaf0;border-radius:16px;padding:8px;box-shadow:0 10px 40px rgba(0,0,0,.45);border:4px solid var(--red)}
.card .head{display:flex;justify-content:space-between;color:#7a1020;font-weight:800;font-size:14px;padding:2px 6px 6px}
.grid{display:grid;grid-template-columns:repeat(9,1fr);gap:4px}
.cell{aspect-ratio:1/1.45;border-radius:8px;display:grid;place-items:center;font-weight:800;font-size:clamp(16px,6vw,40px);
 color:#1b2a22;background:#f3ead6;position:relative}
.cell.empty{background:repeating-linear-gradient(45deg,#e9dcc0,#e9dcc0 4px,#f3ead6 4px,#f3ead6 8px)}
.cell.hit{color:#fff;background:radial-gradient(circle at 40% 35%,#ff6b6b,#c1121f)}
.cell.hit::after{content:"";position:absolute;inset:14%;border-radius:50%;border:2px solid rgba(255,255,255,.55)}
.cell.last{animation:pulse 1s ease 3}
@keyframes pulse{50%{transform:scale(1.18);box-shadow:0 0 18px #ffd166}}
.pick h2{font-size:18px;margin:6px 0;text-align:center}
.pick p{color:var(--soft);text-align:center;margin:4px 0 10px;font-size:14px}
.name{width:100%;font-size:18px;padding:12px 14px;border-radius:12px;border:1px solid rgba(255,209,102,.5);background:rgba(0,0,0,.3);color:var(--ink);margin-bottom:10px}
.ids{display:grid;grid-template-columns:repeat(auto-fill,minmax(54px,1fr));gap:8px;margin-bottom:12px}
.ids button{font-size:18px;font-weight:800;padding:12px 0;border-radius:12px;border:1px solid rgba(255,255,255,.2);background:rgba(255,255,255,.08);color:var(--ink)}
.ids button.sel{background:var(--gold);color:#3b0a12}
.btn{display:block;width:100%;font-size:19px;font-weight:800;padding:15px;border-radius:14px;border:0;margin-top:12px;
 background:linear-gradient(90deg,#c1121f,#e63946);color:#fff;box-shadow:0 6px 24px rgba(230,57,70,.45)}
.btn.alt{background:rgba(255,255,255,.1);box-shadow:none;font-size:15px;padding:11px}
.win{position:fixed;inset:0;z-index:5;display:none;place-items:center;background:rgba(5,10,8,.82);text-align:center;padding:24px}
.win.on{display:grid}
.win div{font-size:44px;font-weight:900;color:var(--gold);text-shadow:0 0 30px rgba(255,209,102,.7);animation:pop .8s ease}
.win p{font-size:19px;color:var(--ink)}
.toast{position:fixed;left:12px;right:12px;bottom:max(14px,env(safe-area-inset-bottom));z-index:4;background:#1d3b2f;border:1px solid var(--gold);
 border-radius:14px;padding:12px 14px;font-weight:700;text-align:center;display:none}
.msg{color:#ffb4a2;text-align:center;font-weight:700;min-height:20px}
.tip{color:var(--soft);font-size:12px;text-align:center;margin-top:10px}
</style></head><body>
<canvas id="snow"></canvas>
<div class="wrap">
 <div class="lights" id="lights"></div>
 <header><img id="logo" alt="" hidden><div><h1>🎄 Tombola napoletana</h1><small id="venue"></small></div></header>
 <div class="now" id="now" hidden><div class="ball" id="ball">–</div><div class="txt"><div class="nap" id="nap"></div><div class="it" id="it"></div></div><div class="sym" id="sym"></div></div>
 <div class="bar" id="bar"></div>
 <section id="pick" class="pick" hidden>
  <h2>Scegli la tua cartella</h2>
  <p>Una sola cartella a persona. I numeri si segnano da soli!</p>
  <input class="name" id="nm" maxlength="24" placeholder="Il tuo nome (facoltativo)" autocomplete="nickname">
  <div class="ids" id="ids"></div>
  <div id="preview"></div>
  <div class="msg" id="msg"></div>
  <button class="btn" id="take" hidden>Gioco con questa cartella 🎁</button>
 </section>
 <section id="play" hidden>
  <div class="card"><div class="head"><span id="cardTitle"></span><span id="cardScore"></span></div><div class="grid" id="grid"></div></div>
  <button class="btn alt" id="fs">⛶ Schermo intero</button>
  <div class="tip">Tieni lo schermo acceso: i numeri arrivano da soli ogni volta che vengono estratti.</div>
 </section>
</div>
<div class="win" id="win"><div><span id="winT"></span><p id="winP">Mostra il telefono al banco per ritirare il premio!</p><button class="btn alt" onclick="win.classList.remove('on')">OK</button></div></div>
<div class="toast" id="toast"></div>
<script>
const base=location.pathname.replace(/\/$/,'');
let cid=localStorage.getItem('tmb_cid');if(!cid){cid=Math.random().toString(36).slice(2)+Date.now().toString(36);localStorage.setItem('tmb_cid',cid)}
nm.value=localStorage.getItem('tmb_name')||'';nm.oninput=()=>localStorage.setItem('tmb_name',nm.value);
for(let i=0;i<22;i++)lights.appendChild(document.createElement('i'));
let tmr=null,S=null,game=null,myCard=null,sel=null,last=null,seenWins=0,celebrated={};
const $=id=>document.getElementById(id);
async function get(p){const r=await fetch(base+p,{cache:'no-store'});return r.json()}
function cardHTML(c,drawn,lastN){const d=new Set(drawn||[]);let h='';
 for(const row of c.rows)for(const n of row){if(!n){h+='<div class="cell empty"></div>';continue}
  h+='<div class="cell'+(d.has(n)?' hit':'')+(n===lastN?' last':'')+'">'+n+'</div>'}return h}
function score(c,drawn){const d=new Set(drawn);let best=0,tot=0;for(const row of c.rows){const k=row.filter(n=>n&&d.has(n)).length;best=Math.max(best,k);tot+=k}return{best,tot}}
async function choose(id){sel=id;msg.textContent='';[...ids.children].forEach(b=>b.classList.toggle('sel',+b.dataset.id===id));
 const c=await get('/card?id='+id);preview.innerHTML='<div class="card"><div class="head"><span>Cartella n. '+id+'</span></div><div class="grid">'+cardHTML(c,[],0)+'</div></div>';take.hidden=false}
take.onclick=async()=>{if(!sel)return;const j=await get('/take?id='+sel+'&cid='+encodeURIComponent(cid)+'&name='+encodeURIComponent(nm.value.trim()));
 if(j.error){msg.textContent=j.error;sel=null;take.hidden=true;preview.innerHTML='';refresh();return}myCard=null;refresh()};
fs.onclick=()=>{const e=document.documentElement;(e.requestFullscreen||e.webkitRequestFullscreen||function(){}).call(e)};
if(!(document.documentElement.requestFullscreen||document.documentElement.webkitRequestFullscreen))fs.hidden=true;
function toast(t){const e=$('toast');e.textContent=t;e.style.display='block';clearTimeout(e._t);e._t=setTimeout(()=>e.style.display='none',6000)}
async function refresh(){try{S=await get('/state?cid='+encodeURIComponent(cid))}catch(e){clearTimeout(tmr);tmr=setTimeout(refresh,2500);return}
 document.body.classList.toggle('plain',!S.xmas);$('snow').style.display=S.xmas?'block':'none';lights.style.display=S.xmas?'flex':'none';
 venue.textContent=S.venue||'';if(S.logo&&logo.hidden){logo.src=base+'/logo';logo.hidden=false}
 if(game&&game!==S.game){myCard=null;sel=null;preview.innerHTML='';take.hidden=true;seenWins=0;celebrated={};toast('🎄 Nuova partita! Scegli la tua cartella')}
 const firstLoad=game===null;game=S.game;
 if(S.current){now.hidden=false;if(last!==S.current){ball.classList.remove('pop');void ball.offsetWidth;ball.classList.add('pop');if(last!==null&&navigator.vibrate)navigator.vibrate(120)}
  ball.textContent=S.current;nap.textContent=S.nap;it.textContent=S.it;sym.textContent=S.sym}else now.hidden=true;
 const mm=Math.floor(S.next/60),ss=String(S.next%60).padStart(2,'0');
 bar.innerHTML=S.finished?'<span><b>Partita finita</b> – grazie a tutti! 🎅</span>':
  '<span>In palio: <b>'+(S.prize||'–')+'</b></span><span>'+(S.running?'Prossimo numero tra <b>'+mm+':'+ss+'</b>':'<b>In pausa</b>')+'</span><span>Usciti: <b>'+S.drawn.length+'</b>/90</span>';
 if(S.wins.length>seenWins){for(const w of S.wins.slice(seenWins)){
   if(S.mine&&w.cards.includes(S.mine)){if(!celebrated[w.prize]){celebrated[w.prize]=1;winT.textContent='🎉 '+w.prize.toUpperCase()+'! 🎉';win.classList.add('on');if(navigator.vibrate)navigator.vibrate([200,100,200,100,400])}}
   else if(!firstLoad)toast('🏆 '+w.prize+' alla cartella '+w.cards.join(', ')+(w.names.filter(Boolean).length?' – '+w.names.filter(Boolean).join(', '):''))}
  seenWins=S.wins.length}
 if(S.mine){pick.hidden=true;play.hidden=false;if(!myCard||myCard.id!==S.mine)myCard=await get('/card?id='+S.mine);
  grid.innerHTML=cardHTML(myCard,S.drawn,S.current);cardTitle.textContent='Cartella n. '+S.mine+(S.myName?' · '+S.myName:'');
  const sc=score(myCard,S.drawn);cardScore.textContent=sc.tot+'/15'}
 else{play.hidden=true;pick.hidden=false;
  const key=S.free.join(',');if(ids.dataset.k!==key){ids.dataset.k=key;ids.innerHTML='';
   if(!S.free.length)ids.innerHTML='<p>Tutte le cartelle sono prese: chiedi al banco.</p>';
   for(const id of S.free){const b=document.createElement('button');b.textContent=id;b.dataset.id=id;if(id===sel)b.classList.add('sel');b.onclick=()=>choose(id);ids.appendChild(b)}
   if(sel&&!S.free.includes(sel)){sel=null;take.hidden=true;preview.innerHTML='';msg.textContent='Quella cartella è stata presa da un altro: scegline un\'altra'}}}
 last=S.current||null;clearTimeout(tmr);tmr=setTimeout(refresh,1500)}
refresh();
// neve
const cv=$('snow'),cx=cv.getContext('2d');let W,H,fl=[];
function rs(){W=cv.width=innerWidth;H=cv.height=innerHeight}rs();addEventListener('resize',rs);
for(let i=0;i<70;i++)fl.push({x:Math.random()*innerWidth,y:Math.random()*innerHeight,r:1+Math.random()*3,s:.3+Math.random()*1.1,w:Math.random()*6});
(function f(t){cx.clearRect(0,0,W,H);cx.fillStyle='rgba(255,255,255,.85)';for(const p of fl){p.y+=p.s;p.x+=Math.sin((t/1000)+p.w)*.4;if(p.y>H){p.y=-5;p.x=Math.random()*W}
 cx.beginPath();cx.arc(p.x,p.y,p.r,0,6.3);cx.fill()}requestAnimationFrame(f)})(0);
</script></body></html>
"""#
}
