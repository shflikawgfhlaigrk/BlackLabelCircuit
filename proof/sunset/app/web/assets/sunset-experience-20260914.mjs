const frame=document.querySelector('[data-studio-frame]');
let observer;
function fitStudio(){
  const content=frame?.contentDocument?.querySelector('#main-content');
  if(!content)return;
  observer?.disconnect();
  observer=new ResizeObserver(()=>{
    frame.style.height=Math.max(240,Math.min(2400,Math.ceil(content.getBoundingClientRect().height+2)))+'px';
  });
  observer.observe(content);
}
frame?.addEventListener('load',fitStudio);
fitStudio();
