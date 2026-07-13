// Rashun Widget for Scriptable — https://scriptable.app
// Script version 1.0.0. This file is self-contained and never downloads code.
const SCRIPT_VERSION = "1.2.0", SNAPSHOT_SCHEMA = 1;
const FM = FileManager.local(), ROOT = FM.joinPath(FM.libraryDirectory(), "rashun-widget");
const CONFIG_PATH = FM.joinPath(ROOT, "config-v1.json"), CACHE_PATH = FM.joinPath(ROOT, "snapshot-v1.json");
// Used only for old cached schema-v1 responses. Current Rashun versions send every theme value.
const FALLBACK_THEME = { background:"#131129", card:"#1C1836", cardAlt:"#241E44", purple:"#935AFD", teal:"#0DE4D1", text:"#FFFFFF", muted:"#B9B4D6", warning:"#FFD166" };

function parseSetup(raw) {
  const prefix = "RASHUN-WIDGET-1:";
  if (!raw || !raw.startsWith(prefix)) throw new Error("That is not a Rashun widget setup code.");
  const value = JSON.parse(decodeURIComponent(escape(atob(raw.slice(prefix.length)))));
  if (value.version !== 1 || !value.endpoint || !value.password) throw new Error("The setup code is incomplete.");
  if (!/^https?:\/\/[^/]+/i.test(value.endpoint)) throw new Error("The Rashun address is invalid.");
  return value;
}
function validSnapshot(value) {
  if (!value || value.schemaVersion !== SNAPSHOT_SCHEMA || !value.device || !Array.isArray(value.items) || !value.appearance) return false;
  return value.items.every(item => typeof item.providerID === "string" && typeof item.metricID === "string" && Number.isFinite(item.remaining) && Number.isFinite(item.limit) && item.limit > 0);
}
function percent(item) { return Math.max(0, Math.min(100, item.remaining / item.limit * 100)); }
function ageText(date, now = new Date()) {
  const seconds = Math.max(0, (now - new Date(date)) / 1000);
  if (seconds < 90) return "Updated now";
  if (seconds < 3600) return `Updated ${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86400) return `Updated ${Math.floor(seconds / 3600)}h ago`;
  return `Updated ${Math.floor(seconds / 86400)}d ago`;
}
function resetText(date, now = new Date()) {
  if (!date) return "No reset time";
  const seconds = (new Date(date) - now) / 1000;
  if (seconds <= 0) return "Reset due";
  if (seconds < 3600) return `Resets in ${Math.max(1, Math.ceil(seconds/60))}m`;
  if (seconds < 86400) return `Resets in ${Math.ceil(seconds/3600)}h`;
  return `Resets in ${Math.ceil(seconds/86400)}d`;
}
function observationDate(snapshot) {
  const dates=(snapshot?.items || []).map(item=>new Date(item.observedAt)).filter(date=>Number.isFinite(date.getTime()));
  return dates.length ? new Date(Math.max(...dates.map(date=>date.getTime()))).toISOString() : snapshot?.generatedAt;
}
function keyFor(deviceID) { return `rashun.widget.${deviceID}`; }
function readJSON(path, fallback) { try { return FM.fileExists(path) ? JSON.parse(FM.readString(path)) : fallback; } catch { return fallback; } }
function writeJSON(path, value) { if (!FM.fileExists(ROOT)) FM.createDirectory(ROOT, true); FM.writeString(path, JSON.stringify(value)); }
function configuration() { return readJSON(CONFIG_PATH, null); }
function credential(config) { return config && Keychain.contains(keyFor(config.deviceID)) ? Keychain.get(keyFor(config.deviceID)) : null; }
function theme(appearance={}) { return {
  background:appearance.backgroundColorHex || FALLBACK_THEME.background, card:appearance.cardColorHex || FALLBACK_THEME.card,
  cardAlt:appearance.cardAlternateColorHex || FALLBACK_THEME.cardAlt, text:appearance.primaryTextColorHex || FALLBACK_THEME.text,
  muted:appearance.secondaryTextColorHex || FALLBACK_THEME.muted, warning:appearance.warningColorHex || FALLBACK_THEME.warning,
  primary:appearance.primaryBrandColorHex || FALLBACK_THEME.purple, accent:appearance.accentBrandColorHex || FALLBACK_THEME.teal,
  track:appearance.ringTrackColorHex || FALLBACK_THEME.cardAlt,
}; }
function safeName(value) { return String(value || "asset").replace(/[^a-z0-9._-]+/gi,"-"); }

async function requestJSON(url, options = {}) {
  const request = new Request(url);
  request.method = options.method || "GET";
  request.headers = options.headers || {};
  request.timeoutInterval = 8;
  request.allowInsecureRequest = !!options.allowInsecure;
  if (options.body) request.body = JSON.stringify(options.body);
  const value = await request.loadJSON();
  const status = request.response && request.response.statusCode;
  if (status < 200 || status >= 300) { const error = new Error(`HTTP ${status}`); error.status = status; throw error; }
  return value;
}
async function pair(setup) {
  if (setup.endpoint.startsWith("http:")) {
    if (!setup.allowInsecureHTTP) throw new Error("Rashun did not authorize an insecure connection.");
    const warning = new Alert(); warning.title = "Trusted network only";
    warning.message = "This Mac uses HTTP. Continue only on a private network you trust.";
    warning.addAction("Continue"); warning.addCancelAction("Cancel");
    if (await warning.presentAlert() < 0) throw new Error("Setup cancelled.");
  }
  const identity = UUID.string(), response = await requestJSON(`${setup.endpoint}/v1/pairing/connect`, {
    method:"POST", allowInsecure:setup.allowInsecureHTTP,
    headers:{"Content-Type":"application/json"},
    body:{ password:setup.password, requesterName:"iOS Widget", requesterDeviceID:identity,
      requesterEpoch:UUID.string(), scope:"widgetRead" }
  });
  if (!response.credential || !response.credential.id || !response.credential.secret) throw new Error("Rashun did not return a widget credential.");
  const config = { version:1, endpoint:setup.endpoint, deviceID:response.host.deviceID,
    deviceName:response.host.displayName || setup.deviceName || "Rashun", openURL:setup.openURL,
    allowInsecureHTTP:!!setup.allowInsecureHTTP };
  Keychain.set(keyFor(config.deviceID), `${response.credential.id}:${response.credential.secret}`);
  writeJSON(CONFIG_PATH, config);
  const snapshot = await fetchSnapshot(config); writeJSON(CACHE_PATH, { version:1, snapshot, savedAt:new Date().toISOString() });
  return { config, snapshot };
}
async function fetchSnapshot(config) {
  const secret = credential(config); if (!secret) { const e = new Error("Reconnect Rashun"); e.status=401; throw e; }
  const value = await requestJSON(`${config.endpoint}/v1/widget/snapshot`, {
    headers:{Authorization:`RashunBearer ${secret}`}, allowInsecure:config.allowInsecureHTTP });
  if (value.schemaVersion > SNAPSHOT_SCHEMA) { const e = new Error("Update Rashun widget"); e.schema=true; throw e; }
  if (!validSnapshot(value)) throw new Error("Rashun returned an invalid widget response.");
  return value;
}
async function loadImages(config,snapshot) {
  const images={}, version=safeName(snapshot.assetVersion || "v1"), paths=[...new Set(snapshot.items.map(item=>item.iconPath).filter(Boolean))];
  await Promise.all(paths.map(async path => {
    const cachePath=FM.joinPath(ROOT,`icon-${version}-${safeName(path)}.png`);
    try {
      if(FM.fileExists(cachePath)) images[path]=FM.readImage(cachePath);
      else {
        const request=new Request(`${config.endpoint}/${path.replace(/^\/+/,"")}`); request.timeoutInterval=6; request.allowInsecureRequest=!!config.allowInsecureHTTP;
        const image=await request.loadImage(), status=request.response && request.response.statusCode;
        if(status>=200 && status<300) { if(!FM.fileExists(ROOT)) FM.createDirectory(ROOT,true); FM.writeImage(cachePath,image); images[path]=image; }
      }
    } catch {}
  }));
  return images;
}
function parseWidgetParameter(raw) {
  const value=String(raw || "").trim(); if(!value) return null;
  const fields=Object.fromEntries(value.split(";").map(part=>part.split("=").map(item=>item.trim())).filter(pair=>pair.length===2));
  if(fields.source || fields.metric) return {providerID:fields.source || null,metricID:fields.metric || null};
  const parts=value.split(":"); return parts.length===2?{providerID:parts[0],metricID:parts[1]}:{providerID:null,metricID:value};
}
function selectedMetric(snapshot,parameter) {
  const parsed=parseWidgetParameter(parameter);
  if(parsed) { const match=snapshot.items.find(item=>(!parsed.providerID || item.providerID===parsed.providerID) && (!parsed.metricID || item.metricID===parsed.metricID)); if(match) return match; }
  return selectedRings(snapshot)[0] || snapshot.items[0];
}
function selectedRings(snapshot, parameter=null) {
  if(parameter) { const selected=selectedMetric(snapshot,parameter); return selected?[selected]:[]; }
  const keys = snapshot.appearance.metrics || [], byKey = new Map(snapshot.items.map(item => [`${item.providerID}:${item.metricID}`, item]));
  const selected = keys.map(key => byKey.get(`${key.providerID}:${key.metricID}`)).filter(Boolean);
  return (selected.length ? selected : snapshot.items).slice(0, 4);
}
function groupedSources(items) {
  const groups=[], byProvider=new Map();
  for(const item of items) {
    let group=byProvider.get(item.providerID);
    if(!group) { group={providerID:item.providerID,sourceName:item.sourceName,headerDetail:item.headerDetail,iconPath:item.iconPath,items:[]}; byProvider.set(item.providerID,group); groups.push(group); }
    group.items.push(item);
  }
  return groups;
}
function ringColor(item, appearance) {
  const colors=theme(appearance);
  if (appearance.colorMode === "monochrome") return colors.text;
  return /^#[0-9a-f]{6}$/i.test(item.displayColorHex || "") ? item.displayColorHex : (/^#[0-9a-f]{6}$/i.test(item.colorHex || "") ? item.colorHex : colors.primary);
}
function hexRGB(hex) { const value=parseInt(String(hex).replace("#",""),16); return {r:(value>>16)&255,g:(value>>8)&255,b:value&255}; }
function mixHex(start,end,fraction) { const a=hexRGB(start),b=hexRGB(end),t=Math.max(0,Math.min(1,fraction)); return `#${[a.r+(b.r-a.r)*t,a.g+(b.g-a.g)*t,a.b+(b.b-a.b)*t].map(v=>Math.round(v).toString(16).padStart(2,"0")).join("")}`; }
function ringImage(item, appearance, size=90, logo=null) {
  const dc = new DrawContext(); dc.size = new Size(size,size); dc.opaque=false; dc.respectScreenScale=true;
  const colors=theme(appearance), center=size/2, radius=size*.355, dot=size*.09, segments=96;
  function drawDots(color, count, gradientEnd=null) {
    for(let index=0; index<count; index++) {
      dc.setFillColor(new Color(gradientEnd?mixHex(color,gradientEnd,index/Math.max(1,count-1)):color));
      const angle=-Math.PI/2 + Math.PI*2*(index/segments), x=center+Math.cos(angle)*radius-dot/2, y=center+Math.sin(angle)*radius-dot/2;
      dc.fillEllipse(new Rect(x,y,dot,dot));
    }
  }
  drawDots(colors.track,segments);
  const progressCount=Math.max(1,Math.round(segments*percent(item)/100));
  if(appearance.colorMode==="brandGradient") drawDots(colors.primary,progressCount,colors.accent); else drawDots(ringColor(item,appearance),progressCount);
  const centerMode=appearance.centerContentMode || "logo", centerColor=appearance.colorMode==="pace"?ringColor(item,appearance):colors.text;
  if(centerMode==="logo" && logo) dc.drawImageInRect(logo,new Rect(size*.33,size*.33,size*.34,size*.34));
  else {
    const value=centerMode==="pacePoints" && Number.isFinite(item.paceScore)?`${item.paceScore>0?"+":""}${Math.round(item.paceScore)}`:`${Math.round(percent(item))}`;
    dc.setFont(Font.boldSystemFont(value.length>3?size*.12:size*.16)); dc.setTextColor(new Color(centerColor)); dc.setTextAlignedCenter(); dc.drawTextInRect(value,new Rect(size*.25,size*.39,size*.5,size*.24));
  }
  if(appearance.showMetricBadges && item.menuBarBadgeText) {
    const text=String(item.menuBarBadgeText).slice(0,9), height=size*.24, width=Math.min(size*.58,Math.max(size*.3,text.length*size*.085)), x=size-width*.96, y=size-height*.94;
    dc.setFillColor(new Color(item.badgeColorHex || mixHex(ringColor(item,appearance),"#000000",.42))); dc.fillRect(new Rect(x+height/2,y,width-height,height)); dc.fillEllipse(new Rect(x,y,height,height)); dc.fillEllipse(new Rect(x+width-height,y,height,height));
    dc.setFont(Font.boldSystemFont(Math.max(8,size*.115))); dc.setTextColor(new Color(colors.text)); dc.setTextAlignedCenter(); dc.drawTextInRect(text,new Rect(x,y+height*.15,width,height*.72));
  }
  return dc.getImage();
}
function addLabel(stack, text, size, color=FALLBACK_THEME.text, weight="regular") {
  const label=stack.addText(text); label.textColor=new Color(color); label.font=weight==="bold"?Font.boldSystemFont(size):Font.systemFont(size); label.lineLimit=1; return label;
}
function addWarning(parent, colors, size=10) {
  const symbol=SFSymbol.named("exclamationmark.triangle.fill"); symbol.applyFont(Font.boldSystemFont(size));
  const image=parent.addImage(symbol.image); image.imageSize=new Size(size+2,size+2); image.tintColor=new Color(colors.warning); return image;
}
function addRing(parent, item, appearance, images={}, displaySize=66) {
  const cell=parent.addStack(); cell.layoutVertically(); cell.centerAlignContent();
  const image=cell.addImage(ringImage(item,appearance,120,images[item.iconPath])); image.imageSize=new Size(displaySize,displaySize);
}
function baseWidget(state) {
  const colors=theme(state.snapshot?.appearance); const widget=new ListWidget(); widget.backgroundColor=new Color(colors.background); widget.setPadding(12,12,12,12);
  widget.refreshAfterDate=new Date(Date.now()+15*60*1000); if (state.config?.openURL) widget.url=state.config.openURL; return widget;
}
function messageWidget(state, title, detail) { const w=baseWidget(state), colors=theme(state.snapshot?.appearance); addLabel(w,"RASHUN",10,colors.accent,"bold"); w.addSpacer(); addLabel(w,title,17,colors.text,"bold"); addLabel(w,detail,10,colors.muted); w.addSpacer(); return w; }
function smallWidget(state) {
  const w=baseWidget(state), snapshot=state.snapshot, colors=theme(snapshot.appearance), rings=selectedRings(snapshot,state.parameter);
  const header=w.addStack(); addLabel(header,"RASHUN",9,colors.text,"bold"); header.addSpacer(); if(rings.some(item=>item.hasWarning)) addWarning(header,colors,9);
  w.addSpacer(3); const grid=w.addStack(); grid.layoutVertically(); grid.centerAlignContent();
  for(let rowIndex=0; rowIndex<(rings.length>2?2:1); rowIndex++) { const row=grid.addStack(); row.centerAlignContent();
    rings.slice(rowIndex*2,rowIndex*2+2).forEach((item,index)=>{ if(index) row.addSpacer(1); addRing(row,item,snapshot.appearance,state.images,rings.length>2?52:66); });
  }
  w.addSpacer(); addLabel(w,ageText(observationDate(snapshot)),8,state.stale?colors.warning:colors.muted);
  return w;
}
function mediumWidget(state) {
  const w=baseWidget(state), snapshot=state.snapshot, colors=theme(snapshot.appearance), limit=state.family==="large"?7:3, items=snapshot.items.slice(0,limit), groups=groupedSources(items);
  const header=w.addStack(); addLabel(header,"RASHUN",11,colors.text,"bold"); header.addSpacer(); addLabel(header,ageText(observationDate(snapshot)),8,state.stale?colors.warning:colors.muted);
  w.addSpacer(6);
  groups.forEach((group,groupIndex)=>{
    const source=w.addStack(); source.centerAlignContent(); const logo=state.images[group.iconPath];
    if(logo) { const icon=source.addImage(logo); icon.imageSize=new Size(13,13); source.addSpacer(5); }
    addLabel(source,group.sourceName || group.providerID,11,colors.muted,"bold");
    if(group.headerDetail) { source.addSpacer(6); addLabel(source,group.headerDetail,8,colors.muted); }
    w.addSpacer(3);
    group.items.forEach((item,itemIndex)=>{ const color=ringColor(item,snapshot.appearance), row=w.addStack(); row.centerAlignContent();
      addLabel(row,item.metricTitle || item.metricID,9,colors.muted,"bold"); row.addSpacer(7);
      const bar=row.addStack(); bar.size=new Size(0,5); bar.cornerRadius=3; bar.backgroundColor=new Color(colors.cardAlt); const fill=bar.addStack(); fill.size=new Size(Math.max(2,percent(item)*1.9),5); fill.cornerRadius=3; fill.backgroundColor=new Color(color);
      row.addSpacer(7); if(item.hasWarning) { addWarning(row,colors,8); row.addSpacer(5); } addLabel(row,`${Math.round(percent(item))}%`,11,color,"bold");
      if(item.detailText) { const detail=w.addStack(); addLabel(detail,item.detailText,8,colors.muted); }
      if(itemIndex<group.items.length-1) w.addSpacer(4);
    });
    if(groupIndex<groups.length-1) w.addSpacer(7);
  }); return w;
}
function accessoryWidget(state) {
  const w=baseWidget(state), item=selectedMetric(state.snapshot,state.parameter), colors=theme(state.snapshot.appearance); w.setPadding(2,2,2,2); w.addAccessoryWidgetBackground=true;
  if(!item) return messageWidget(state,"No metric","Choose a metric parameter.");
  if(state.family==="accessoryRectangular") { const row=w.addStack(); row.centerAlignContent(); const image=row.addImage(ringImage(item,state.snapshot.appearance,72,state.images[item.iconPath])); image.imageSize=new Size(36,36); row.addSpacer(5); const labels=row.addStack(); labels.layoutVertically(); addLabel(labels,item.metricTitle || item.metricID,10,colors.text,"bold"); addLabel(labels,`${Math.round(percent(item))}% · ${resetText(item.resetAt).replace("Resets ","")}`,9,colors.muted); }
  else { const image=w.addImage(ringImage(item,state.snapshot.appearance,100,state.images[item.iconPath])); image.imageSize=new Size(50,50); image.centerAlignImage(); }
  return w;
}
async function readyState(kind,config,snapshot,stale,parameter,family) { return {kind,config,snapshot,stale,parameter,family,images:await loadImages(config,snapshot)}; }
async function loadState(parameter=null,family="small") {
  const config=configuration(), cached=readJSON(CACHE_PATH,null);
  if (!config) return {kind:"unconfigured",config:null};
  try { const snapshot=await fetchSnapshot(config); writeJSON(CACHE_PATH,{version:1,snapshot,savedAt:new Date().toISOString()}); return await readyState("ready",config,snapshot,false,parameter,family); }
  catch(error) { if(error.status===401) return {kind:"unauthorized",config}; if(error.schema) return {kind:"schema",config}; if(cached && validSnapshot(cached.snapshot)) return await readyState("ready",config,cached.snapshot,true,parameter,family); return {kind:"offline",config}; }
}
async function setupMenu() {
  const alert=new Alert(); alert.title="Rashun Widget"; alert.message=`Version ${SCRIPT_VERSION}`;
  alert.addAction("Set up from clipboard"); alert.addAction("Preview small"); alert.addAction("Preview medium"); alert.addAction("Preview Lock Screen ring"); alert.addDestructiveAction("Remove setup"); alert.addCancelAction("Done");
  const choice=await alert.presentSheet();
  if(choice===0) { try { const result=await pair(parseSetup(Pasteboard.pasteString())); const ok=new Alert(); ok.title="Widget connected"; ok.message=`Connected to ${result.config.deviceName}. Your display changes will update automatically.`; ok.addAction("Preview widget"); await ok.presentAlert(); await smallWidget({config:result.config,snapshot:result.snapshot,stale:false,images:await loadImages(result.config,result.snapshot)}).presentSmall(); } catch(error) { const a=new Alert(); a.title="Setup couldn’t finish"; a.message=error.message; a.addAction("OK"); await a.presentAlert(); } }
  if(choice===1 || choice===2) { const state=await loadState(), widget=renderWidget(state,choice===1?"small":"medium"); await (choice===1?widget.presentSmall():widget.presentMedium()); }
  if(choice===3) { const state=await loadState(null,"accessoryCircular"), widget=renderWidget(state,"accessoryCircular"); await widget.presentAccessoryCircular(); }
  if(choice===4) { const config=configuration(); if(config && Keychain.contains(keyFor(config.deviceID))) Keychain.remove(keyFor(config.deviceID)); if(FM.fileExists(CONFIG_PATH)) FM.remove(CONFIG_PATH); if(FM.fileExists(CACHE_PATH)) FM.remove(CACHE_PATH); }
}
function renderWidget(state,family) {
  if(state.kind==="unconfigured") return messageWidget(state,"Run in Scriptable","Set up your Rashun widget once.");
  if(state.kind==="unauthorized") return messageWidget(state,"Reconnect Rashun","Run this script to pair again.");
  if(state.kind==="schema") return messageWidget(state,"Update widget script","This Rashun version uses a newer format.");
  if(state.kind==="offline") return messageWidget(state,"Mac unavailable","Open Rashun on your Mac, then try again.");
  if(String(family).startsWith("accessory")) return accessoryWidget(state);
  return family==="small"?smallWidget(state):mediumWidget(state);
}

if (typeof module !== "undefined") module.exports={parseSetup,validSnapshot,percent,ageText,resetText,observationDate,groupedSources,selectedRings,selectedMetric,parseWidgetParameter,ringImage,theme};
async function main() {
  if(config.runsInApp) await setupMenu();
  else { const family=config.widgetFamily || "small", state=await loadState(args.widgetParameter,family), widget=renderWidget(state,family); Script.setWidget(widget); }
  Script.complete();
}
if (typeof config !== "undefined") main();
