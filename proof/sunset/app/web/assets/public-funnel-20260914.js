(function(){
  'use strict';
  var host=location.hostname,path=location.pathname,script=document.currentScript;
  if(!script||script.getAttribute('data-site')!==host||/(?:\.pages\.dev|\.workers\.dev)$/.test(host)||host==='localhost'||/^[\d.:]+$/.test(host)||window.__publicFunnelLoaded)return;
  var pageviews=script.getAttribute('data-pageviews')==='true';
  var publicPaths;try{publicPaths=JSON.parse(script.getAttribute('data-public-paths')||'null');if(!Array.isArray(publicPaths))publicPaths=null;}catch(e){publicPaths=null;}
  window.__publicFunnelLoaded=true;
  var privatePath=/^\/(?:api|account|auth|oauth|signin|signup|dashboard|me|admin|envelopes?|sign|verify|status|intake|checkout|buy|webhook)(?:\/|$)/i;
  function isPrivate(p){return privatePath.test(p)&&!(host==='blacklabeltec.com'&&p==='/sign');}
  if(isPrivate(path))return;
  var excluded=navigator.webdriver===true||navigator.globalPrivacyControl===true||navigator.doNotTrack==='1'||window.doNotTrack==='1';
  try{
    if(new URLSearchParams(location.search).get('internal')==='1')sessionStorage.setItem('bl_public_internal','1');
    excluded=excluded||sessionStorage.getItem('bl_public_internal')==='1'||localStorage.getItem('blb_internal')==='1'||localStorage.getItem('blb_analytics_opt_out')==='1';
  }catch(e){excluded=true;}
  document.addEventListener('click',function(e){
    var b=e.target&&e.target.closest&&e.target.closest('[data-public-analytics-optout]');
    if(!b)return;
    try{localStorage.setItem('blb_analytics_opt_out','1');excluded=true;if(window.posthog&&typeof window.posthog.opt_out_capturing==='function')window.posthog.opt_out_capturing();b.textContent='Public-page analytics disabled on this browser';}catch(err){b.textContent='Enable Do Not Track or Global Privacy Control in your browser to opt out';}
  });
  if(excluded)return;
  var id;
  try{id=sessionStorage.getItem('bl_public_session');if(!id){id=crypto.randomUUID();sessionStorage.setItem('bl_public_session',id);}}catch(e){return;}
  function capture(event,extra){
    var currentPath=location.pathname;
    if(excluded||isPrivate(currentPath)||(publicPaths&&!publicPaths.includes(currentPath)))return;
    var props={distinct_id:id,$process_person_profile:false,$geoip_disable:true,$lib:'web',$raw_user_agent:navigator.userAgent,$current_url:location.origin+currentPath,$host:host,$pathname:currentPath,site:host,release:'20260914-public-funnel',...extra};
    var body=JSON.stringify({api_key:'phc_s3fBdVNLuuao2cA9XkA3EMoZ5iLusCWHZzZQWudYW2jo',event:event,properties:props});
    try{fetch('https://us.i.posthog.com/capture/',{method:'POST',headers:{'content-type':'text/plain'},body:body,credentials:'omit',keepalive:true}).catch(function(){});}catch(e){}
  }
  var referrer='';try{referrer=document.referrer?new URL(document.referrer).hostname:'';}catch(e){}
  var entry={$referring_domain:referrer||'$direct',$referrer:referrer?'https://'+referrer+'/':'',$viewport_width:window.innerWidth};
  capture('funnel_entry',entry);if(pageviews)capture('$pageview',entry);
  function routeChanged(){if(path===location.pathname)return;path=location.pathname;capture('funnel_entry',entry);if(pageviews)capture('$pageview',entry);}
  if(window.history){['pushState','replaceState'].forEach(function(method){var original=window.history[method];if(typeof original!=='function')return;window.history[method]=function(){var result=original.apply(this,arguments);routeChanged();return result;};});window.addEventListener('popstate',routeChanged);}
  document.addEventListener('click',function(e){
    var a=e.target&&e.target.closest&&e.target.closest('a[href],button[data-action],button[data-workspace-select],button[data-shop-filter],button[data-scene],button[data-room],button[data-k],button[role="tab"],button[data-active],button.record-trigger,button#start-free,button#master,button#ppA,button#ppB,button#prepare-sponsor-packet');if(!a)return;
    if(a.hasAttribute('data-public-analytics-optout'))return;
    if(!a.getAttribute('href')){
      var actions={master:'mastering_attempt',ppA:'audition_original',ppB:'audition_mastered','start-free':'start_form','prepare-sponsor-packet':'sponsor_packet_attempt'};
      var action=actions[a.id]||(a.hasAttribute('data-workspace-select')?'workspace_select':a.hasAttribute('data-shop-filter')?'product_filter':a.hasAttribute('data-scene')?'scene_try':a.hasAttribute('data-room')?'room_try':a.hasAttribute('data-k')?'audio_preset':a.getAttribute('role')==='tab'?'tool_tab':a.hasAttribute('data-active')?'league_select':a.classList&&a.classList.contains('record-trigger')?'record_start':a.getAttribute('data-action'));
      var choice=a.getAttribute('data-workspace-select')||a.getAttribute('data-shop-filter')||a.getAttribute('data-scene')||a.getAttribute('data-room')||a.getAttribute('data-k')||'';
      if(action)capture('funnel_intent',{conversion_type:'try_tool',action:action,action_value:/^[a-z0-9_-]{1,40}$/i.test(choice)?choice:'',link_id:a.id||''});
      return;
    }
    var href=a.getAttribute('href')||'',target;
    try{target=new URL(href,location.href);}catch(err){return;}
    if(!/^https?:$/.test(target.protocol))return;
    var type='';
    if(target.hostname==='buy.stripe.com'||target.hostname==='payanagent.com'||/^\/(?:buy|api\/(?:buy|checkout))(?:\/|$)/.test(target.pathname))type='checkout';
    else if(/^\/(?:account|signin|signup)(?:\/|$)/.test(target.pathname)||target.hostname==='claude.ai')type='signup';
    else if(target.pathname==='/contact'||target.pathname==='/custom-software-development')type='contact';
    else if(target.pathname==='/start')type='signup';
    else if(target.hash==='#studio'||target.hash==='#try-first'||target.pathname==='/studio/'||target.hash==='#continuity-audit')type='try_tool';
    else if(target.hash==='#checkout')type='checkout_details';
    if(!type)return;
    var detail={conversion_type:type,destination:target.origin+target.pathname,link_id:a.id||''};
    capture('funnel_intent',detail);if(pageviews){capture('conversion_cta_clicked',detail);if(type==='checkout')capture('checkout_click',detail);}
  },true);
  document.addEventListener('submit',function(e){var detail={form_id:e.target&&e.target.id||'',submission_stage:'attempt'};capture('funnel_form_attempt',detail);if(pageviews)capture('form_submit',detail);},true);
})();
