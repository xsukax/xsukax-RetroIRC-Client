#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="xsukax RetroIRC Client"
APP_DIR="/opt/xsukax-retroirc"
APP_FILE="$APP_DIR/app.py"
SERVICE_FILE="/etc/systemd/system/xsukax-retroirc.service"
CONFIG_FILE="/etc/default/xsukax-retroirc"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$0" "$@"
  fi
  echo "This installer must run as root (or with sudo)." >&2
  exit 1
fi

if [[ "${1:-}" == "--uninstall" ]]; then
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now xsukax-retroirc.service >/dev/null 2>&1 || true
  fi
  rm -f "$SERVICE_FILE"
  rm -rf "$APP_DIR"
  rm -f "$CONFIG_FILE"
  if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload || true; fi
  echo "$APP_NAME removed."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends python3 python3-aiohttp ca-certificates

install -d -m 0755 "$APP_DIR"
cat > "$APP_FILE" <<'PYAPP_XSUKAX_EOF_V214_STABILITY'
#!/usr/bin/env python3
from __future__ import annotations

import asyncio
import base64
import ipaddress
import json
import logging
import os
import re
import socket
import ssl
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import urlsplit

from aiohttp import WSMsgType, web

APP_NAME = "xsukax RetroIRC Client"
VERSION = "2.1.4"
BIND = os.getenv("XSUKAX_BIND", "127.0.0.1")
PORT = int(os.getenv("XSUKAX_PORT", "8785"))
ALLOW_PRIVATE_IRC = os.getenv("ALLOW_PRIVATE_IRC", "0") == "1"
ALLOW_CROSS_ORIGIN = os.getenv("ALLOW_CROSS_ORIGIN", "0") == "1"
IRC_CONNECT_TIMEOUT = max(10.0, float(os.getenv("XSUKAX_IRC_CONNECT_TIMEOUT", "35")))
WS_SETUP_TIMEOUT = max(30.0, float(os.getenv("XSUKAX_WS_SETUP_TIMEOUT", "120")))
WS_HEARTBEAT = max(20.0, float(os.getenv("XSUKAX_WS_HEARTBEAT", "60")))

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("xsukax-retroirc")

AUTH_MODES = {"nickserv", "sasl", "serverpass", "undernet", "quakenet", "gamesurge"}
NICK_BAD = re.compile(r"[\s,:\x00-\x1f#&]")
HOST_BAD = re.compile(r"[\s/\\@]")

HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light">
<title>xsukax RetroIRC Client — Classic MSN-era IRC</title>
<style>
:root{
    --classic-bg:#d4d0c8;
    --classic-light:#ffffff;
    --classic-mid:#c0c0c0;
    --classic-dark:#808080;
    --classic-shadow:#404040;
    --navy:#0a246a;
    --navy2:#3a6ea5;
    --select:#0a246a;
    --select-text:#fff;
    --panel:#f5f3ee;
    --chat:#fff;
    --blue:#003399;
    --status:#ffffe1;
    --green:#0a6b20;
    --red:#a00000;
}
*{box-sizing:border-box}
html,body{min-height:100%;min-height:100dvh;margin:0}
body{
    font-family:Tahoma,Verdana,Arial,sans-serif;
    font-size:12px;
    background:#48779a;
    color:#000;
    overflow:auto;
    display:flow-root;
    -webkit-text-size-adjust:100%;
}
button,input,select,textarea{font:inherit}
button{
    min-height:24px;
    padding:2px 10px;
    border:1px solid;
    border-color:#fff #404040 #404040 #fff;
    background:var(--classic-bg);
    color:#000;
}
button:active{border-color:#404040 #fff #fff #404040;padding:3px 9px 1px 11px}
button:disabled{color:#777;text-shadow:1px 1px #fff}
input,select,textarea{
    border:2px inset #fff;
    background:#fff;
    color:#000;
    padding:3px 5px;
}
input:focus,select:focus,textarea:focus{outline:1px dotted #111;outline-offset:-3px}
.checkbox-row{display:flex;align-items:center;gap:6px}
.checkbox-row input{width:auto}
.classic-window{
    border:2px solid;
    border-color:#fff #222 #222 #fff;
    background:var(--classic-bg);
    box-shadow:2px 2px 0 rgba(0,0,0,.25);
}
.titlebar{
    height:27px;
    display:flex;
    align-items:center;
    justify-content:space-between;
    padding:3px 4px 3px 6px;
    color:#fff;
    font-weight:bold;
    background:linear-gradient(90deg,var(--navy),#527fb6);
    user-select:none;
}
.titlebar .caption{display:flex;align-items:center;gap:6px}
.app-glyph{
    width:16px;height:16px;background:#fff;border:1px solid #002f63;position:relative
}
.app-glyph:before,.app-glyph:after{content:"";position:absolute;background:#2f72b7}
.app-glyph:before{left:2px;right:2px;top:3px;height:3px}
.app-glyph:after{left:4px;right:4px;bottom:2px;height:5px}
.win-buttons{display:flex;gap:2px}
.win-btn{width:20px;min-height:18px;height:18px;padding:0;line-height:14px;font-weight:bold}
.menu-bar{
    height:24px;
    display:flex;
    align-items:center;
    gap:2px;
    padding:1px 4px;
    border-bottom:1px solid #808080;
    background:var(--classic-bg);
}
.menu-item{padding:3px 7px;cursor:pointer;user-select:none}
.menu-item:hover{background:var(--select);color:#fff}
.toolbar{
    display:flex;
    align-items:center;
    gap:4px;
    min-height:38px;
    padding:4px;
    border-top:1px solid #fff;
    border-bottom:1px solid #808080;
    background:var(--classic-bg);
}
.tool{
    min-width:60px;
    height:29px;
    display:flex;
    align-items:center;
    justify-content:center;
    gap:5px;
}
.sep{width:1px;height:27px;background:#808080;border-right:1px solid #fff;margin:0 3px}
.statusbar{
    min-height:31px;
    height:31px;
    display:flex;
    gap:3px;
    align-items:stretch;
    padding:4px 3px;
    border-top:1px solid #fff;
    background:var(--classic-bg);
}
.statuscell{
    border:1px inset #fff;
    padding:3px 7px;
    line-height:16px;
    display:flex;
    align-items:center;
    overflow:hidden;
    white-space:nowrap;
    text-overflow:ellipsis;
}
.statuscell.flex{flex:1}
#landing{
    width:96vw;
    height:96vh;
    height:96dvh;
    max-width:96vw;
    max-height:96vh;
    max-height:96dvh;
    margin:2vh auto;
    overflow:auto;
    padding:16px;
    background:
        radial-gradient(circle at 20% 10%,rgba(255,255,255,.24),transparent 24%),
        linear-gradient(#6b9fbd,#37647f);
}
.connect-window{max-width:1040px;margin:0 auto}
.connect-body{padding:12px}
.hero{
    display:grid;
    grid-template-columns:1.35fr .65fr;
    gap:12px;
    margin-bottom:12px;
}
.hero-card,.tip-card{
    border:2px groove #fff;
    background:#ece9e2;
    padding:14px;
}
.hero-card h1{font-size:20px;color:#17375e;margin:0 0 7px}
.hero-card p{margin:4px 0;line-height:1.45}
.tip-card{background:#ffffe1}
fieldset{
    border:2px groove #fff;
    margin:0 0 10px;
    padding:10px;
}
legend{font-weight:bold;padding:0 5px}
.server-grid{
    display:grid;
    grid-template-columns:repeat(4,minmax(0,1fr));
    gap:6px;
}
.server-card{
    min-height:54px;
    text-align:left;
    padding:6px 8px;
    display:block;
    overflow:hidden;
}
.server-card strong,.server-card small{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.server-card small{margin-top:3px;color:#444}
.server-card.active{
    background:#0a246a;
    color:#fff;
    border-color:#000 #fff #fff #000;
}
.server-card.active small{color:#eaf2ff}
.server-card.custom{font-weight:bold}
.form-grid{
    display:grid;
    grid-template-columns:140px minmax(0,1fr) 125px minmax(120px,.65fr);
    gap:7px 9px;
    align-items:center;
}
.form-grid label{text-align:right}
.span3{grid-column:2 / 5}
.auth-box{
    margin-top:8px;
    padding:9px;
    border:1px solid #808080;
    background:#e9e7e1;
}
.auth-grid{
    display:grid;
    grid-template-columns:140px minmax(0,1fr);
    gap:7px 9px;
    align-items:center;
}
.auth-grid label{text-align:right}
.connect-actions{display:flex;justify-content:flex-end;gap:7px;margin-top:10px}
#connectError{
    display:none;
    margin-top:8px;
    border:1px solid #a00;
    background:#fff1f1;
    color:#7b0000;
    padding:7px 9px;
}
#client{display:none;width:96vw;height:96vh;height:96dvh;max-width:96vw;max-height:96vh;max-height:96dvh;margin:2vh auto;padding:0;background:#3f6680;overflow:hidden}
#client.restored{width:86vw;height:86vh;max-width:86vw;max-height:86vh;margin:7vh auto}
.client-window{width:100%;height:100%;min-height:0;display:flex;flex-direction:column;overflow:hidden}
.workspace{flex:1;min-height:0;overflow:hidden;display:grid;grid-template-columns:160px minmax(0,1fr);background:#b7b7b7}
.navpane{
    min-width:0;
    min-height:0;
    overflow:hidden;
    border-right:2px groove #fff;
    background:#ece9e2;
    display:flex;
    flex-direction:column;
}
.navhead{
    padding:6px;
    color:#fff;
    background:#315b88;
    font-weight:bold;
}
.tree{flex:1;overflow:auto;padding:4px}
.tree-item{
    padding:4px 5px;
    cursor:default;
    display:flex;
    gap:5px;
    align-items:center;
    white-space:nowrap;
    overflow:hidden;
    text-overflow:ellipsis;
}
.tree-item:hover{background:#d8e5f2}
.tree-item.active{background:#0a246a;color:#fff}
.dot{width:9px;height:9px;border:1px solid #444;background:#9a9a9a;display:inline-block;flex:0 0 auto}
.dot.channel{background:#52a452}
.dot.query{background:#d99a34}
.dot.status{background:#5d7fc7}
.roomarea{min-width:0;min-height:0;overflow:hidden;display:flex;flex-direction:column;background:var(--classic-bg)}
.tabstrip{
    min-height:32px;
    flex:0 0 auto;
    display:flex;
    align-items:flex-end;
    gap:2px;
    padding:3px 5px 0;
    overflow-x:auto;
    overflow-y:hidden;
    border-bottom:1px solid #808080;
    background:#d8d5ce;
}
.tab{
    padding:0 3px 0 9px;
    min-height:25px;
    display:flex;
    align-items:center;
    gap:5px;
    border:1px solid;
    border-color:#fff #777 #777 #fff;
    background:#c7c4bd;
    cursor:default;
    white-space:nowrap;
}
.tab-label{max-width:190px;overflow:hidden;text-overflow:ellipsis}
.tab-close,.tree-close{min-height:18px;height:18px;min-width:18px;width:18px;padding:0;line-height:14px;font-weight:bold;border-color:transparent;background:transparent}
.tab-close:hover,.tree-close:hover{border:1px solid;border-color:#fff #555 #555 #fff;background:#d4d0c8}
.tree-label{overflow:hidden;text-overflow:ellipsis;flex:1}
.tab.active{
    background:#f6f4ef;
    border-bottom-color:#f6f4ef;
    font-weight:bold;
}
.room-banner{
    min-height:46px;
    padding:6px 9px;
    border-bottom:1px solid #999;
    background:linear-gradient(#edf5fb,#cfdeea);
}
.room-title{font-size:15px;font-weight:bold;color:#123e69}
.room-topic{color:#333;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.room-content{
    flex:1;min-height:0;
    overflow:hidden;
    display:grid;
    grid-template-columns:minmax(0,1fr) 210px;
    gap:4px;
    padding:4px;
}
.transcript{
    min-width:0;
    min-height:0;
    overflow:auto;
    overscroll-behavior:contain;
    background:var(--chat);
    border:2px inset #fff;
    padding:5px 7px;
    font-family:Tahoma,Verdana,Arial,sans-serif;
}
.msg{line-height:1.42;white-space:pre-wrap;overflow-wrap:anywhere}
.msg .time{color:#8a8a8a;margin-right:5px}
.msg.join{color:#17741d}
.msg.part{color:#8c5b00}
.msg.notice{color:#6a3a8f}
.msg.error{color:#a00000;font-weight:bold}
.msg.system{color:#555}
.msg.action{color:#7b2f70}
.msg.self .nick{color:#003c91}
.msg .nick{font-weight:bold}
.people{
    display:flex;
    flex-direction:column;
    min-width:0;
    min-height:0;
    overflow:hidden;
    background:#f8f7f3;
    border:2px inset #fff;
}
.people-head{
    padding:5px 6px;
    background:#d9e5ef;
    border-bottom:1px solid #999;
    font-weight:bold;
}
.user-list{flex:1;min-height:0;overflow:auto;overscroll-behavior:contain;padding:2px}
.user-row{
    display:flex;
    align-items:center;
    min-height:22px;
    gap:5px;
    padding:3px 4px;
    white-space:nowrap;
    cursor:default;
}
.user-row:hover{background:#e1ebf5}
.user-row.selected{background:#0a246a;color:#fff}
.user-nick{overflow:hidden;text-overflow:ellipsis}
.hammer{
    width:14px;height:14px;display:inline-block;position:relative;flex:0 0 14px;
    color:#8b5a2b;transform:rotate(-4deg)
}
.hammer:before{
    content:"";position:absolute;width:3px;height:11px;left:6px;top:3px;
    background:currentColor;transform:rotate(-35deg);transform-origin:center
}
.hammer:after{
    content:"";position:absolute;width:10px;height:4px;left:1px;top:1px;
    background:currentColor;border:1px solid rgba(60,30,0,.45)
}
.hammer.mode-q{color:#f0c62d} /* +q founder/owner: yellow on every network */
.hammer.mode-a{color:#8b5a2b} /* +a admin/protected: brown */
.hammer.mode-o{color:#b22b2b} /* +o channel operator: red */
.hammer.mode-h{color:#2f65b0} /* +h half-operator: blue */
.hammer.mode-v{color:#27843a} /* +v voice: green */
.hammer.mode-extra-1{color:#7a3aa5} /* deterministic server-specific membership status */
.hammer.mode-extra-2{color:#16837f}
.hammer.mode-extra-3{color:#c56b16}
.hammer.mode-extra-4{color:#7b4f9d}
.hammer.ordinary{color:#9a9a9a} /* no channel membership prefix: gray */
.legend-unsupported{opacity:.48}
.role-name{font-weight:bold}
.role-code{color:#555;font-family:Consolas,"Courier New",monospace}
.role-legend{
    border-top:1px solid #aaa;
    padding:5px 6px;
    font-size:11px;
    line-height:1.5;
    background:#ffffe1;
}
.legend-line{display:flex;align-items:center;gap:5px}
.modbar{
    display:none;
    gap:4px;
    flex-wrap:wrap;
    padding:5px;
    border-top:1px solid #999;
    background:#ece9e2;
}
.composer{
    display:grid;
    grid-template-columns:1fr auto;
    gap:5px;
    padding:5px;
    border-top:1px solid #fff;
    background:var(--classic-bg);
}
#messageInput{height:29px}
#sendBtn{min-width:70px}
.overlay{
    display:none;
    position:fixed;
    z-index:30;
    inset:0;
    background:rgba(0,0,0,.28);
    align-items:center;
    justify-content:center;
    padding:20px;
}
.dialog{
    width:min(680px,95vw);
    max-height:88vh;
    display:flex;
    flex-direction:column;
}
.dialog-body{padding:10px;overflow:auto;background:var(--classic-bg)}
.dialog-actions{display:flex;justify-content:flex-end;gap:6px;padding:7px;border-top:1px solid #999}
.props-grid{display:grid;grid-template-columns:150px 1fr;gap:7px 9px;align-items:center}
.props-grid label{text-align:right}
.mode-options{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:6px;margin:8px 0}
.mode-options label{text-align:left}
.user-admin{
    margin-top:10px;padding-top:10px;border-top:1px solid #999;
    display:grid;grid-template-columns:1fr 1fr;gap:6px;
}
.ban-list{border:2px inset #fff;background:#fff;max-height:125px;overflow:auto;margin-top:6px}
.ban-row{display:flex;justify-content:space-between;gap:6px;padding:4px;border-bottom:1px solid #eee}
.room-list{
    width:100%;
    border-collapse:collapse;
    background:#fff;
    border:2px inset #fff;
}
.room-list th,.room-list td{padding:4px 6px;border-bottom:1px solid #ddd;text-align:left}
.room-list th{background:#d9e5ef;position:sticky;top:0;z-index:1;padding:0}
.room-list tr:hover td{background:#eaf2fb}
.sort-head{width:100%;border:0;background:#d9e5ef;text-align:left;padding:5px 6px;min-height:25px}
.sort-head:hover{background:#c7d9e8}
.help-code{
    font-family:Consolas,"Courier New",monospace;
    background:#fff;border:2px inset #fff;padding:8px;white-space:pre-wrap
}
.muted{color:#666}
.good{color:#0a6b20}
.bad{color:#a00000}
.context-menu{
    display:none;
    max-height:calc(100vh - 12px);
    overflow:auto;
    position:fixed;
    z-index:80;
    min-width:185px;
    max-height:min(420px,80vh);
    overflow:auto;
    padding:2px;
    border:2px solid;
    border-color:#fff #202020 #202020 #fff;
    background:var(--classic-bg);
    box-shadow:2px 2px 4px rgba(0,0,0,.35);
}
.context-menu.open{display:block}
.context-menu button{
    display:block;
    width:100%;
    min-height:24px;
    border:0;
    padding:4px 22px 4px 8px;
    text-align:left;
    background:transparent;
}
.context-menu button:hover:not(:disabled){background:#0a246a;color:#fff}
.context-menu button:disabled{color:#888}
.context-sep{height:1px;margin:3px 2px;background:#808080;border-bottom:1px solid #fff}
.titlebar,.menu-bar,.toolbar,.statusbar,.room-banner,.composer{flex-shrink:0}
.toolbar{overflow-x:auto;overflow-y:hidden}
#peopleToggleBtn{display:none}
#peopleCloseBtn{display:none;min-width:22px;width:22px;height:20px;min-height:20px;padding:0;font-weight:bold}
.people-head-inner{display:flex;align-items:center;justify-content:space-between;gap:6px}

/* Tablet layout: preserve both room navigation and people list, but give chat priority. */
@media(max-width:1024px){
    .connect-window{max-width:none;width:100%}
    .hero{grid-template-columns:1fr}
    .server-grid{grid-template-columns:repeat(3,minmax(0,1fr))}
    .workspace{grid-template-columns:130px minmax(0,1fr)}
    .room-content{grid-template-columns:minmax(0,1fr) 180px}
    .tool{min-width:auto;padding:2px 7px}
    .tab-label{max-width:145px}
}

/* Phone layout: chat gets the full content width. People becomes an on-demand drawer. */
@media(max-width:700px){
    #landing{padding:6px;width:96vw;height:96vh;height:96dvh;max-height:96dvh;margin:2vh auto}
    #client{width:96vw;height:96vh;height:96dvh;max-height:96dvh;margin:2vh auto}
    #client.restored{width:96vw;height:96vh;height:96dvh;max-width:96vw;max-height:96dvh;margin:2vh auto}
    .connect-body{padding:7px}
    .hero{display:block;margin-bottom:7px}
    .tip-card{margin-top:7px}
    .server-grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:5px}
    .server-card{min-height:48px;padding:5px 6px}
    .form-grid,.auth-grid{grid-template-columns:1fr;gap:4px}
    .form-grid label,.auth-grid label{text-align:left;margin-top:3px}
    .form-grid .wide-label,.form-grid .wide-field,.span3{grid-column:1}
    .connect-actions{position:sticky;bottom:0;background:var(--classic-bg);padding-top:6px;z-index:3}
    .titlebar .caption{min-width:0;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}
    .titlebar .caption span:last-child{overflow:hidden;text-overflow:ellipsis}
    .toolbar{min-height:36px;padding:3px;gap:3px;-webkit-overflow-scrolling:touch}
    .toolbar .tool{height:28px;min-width:auto;padding:2px 7px}
    .sep{height:25px;margin:0 1px}
    #peopleToggleBtn{display:flex}
    .workspace{grid-template-columns:minmax(0,1fr)}
    .navpane{display:none}
    .room-content{grid-template-columns:minmax(0,1fr);position:relative;padding:3px}
    .people{display:none;position:absolute;right:0;top:0;bottom:0;width:min(86vw,330px);z-index:20;box-shadow:-4px 0 10px rgba(0,0,0,.35)}
    .people.mobile-open{display:flex}
    #peopleCloseBtn{display:inline-block}
    .role-legend{max-height:38%;overflow:auto}
    .modbar{max-height:36%;overflow:auto}
    .tabstrip{min-height:31px;-webkit-overflow-scrolling:touch}
    .tab-label{max-width:125px}
    .room-banner{min-height:42px;padding:5px 7px}
    .room-title{font-size:14px}
    .composer{padding:4px;gap:4px}
    #messageInput{height:32px;font-size:16px;min-width:0}
    #sendBtn{min-width:58px;height:32px}
    .statusbar{min-height:34px;height:34px;padding:4px 2px;gap:2px;font-size:11px}
    .statuscell{padding:3px 4px;min-width:0}
    #nickStatus{max-width:34vw}
    #secureStatus{max-width:17vw}
    .overlay{padding:5px}
    .dialog{width:94vw;max-height:92vh;max-height:92dvh}
    .props-grid{grid-template-columns:1fr;gap:4px}
    .props-grid label{text-align:left}
    .mode-options{grid-template-columns:1fr}
    .user-admin{grid-template-columns:1fr}
}

@media(max-width:420px){
    .server-grid{grid-template-columns:1fr}
    .hero-card,.tip-card{padding:9px}
    .hero-card h1{font-size:17px}
    fieldset{padding:7px}
    .toolbar .tool{padding:2px 6px}
    .statuscell{font-size:10px}
}

.room-list-status{
    min-height:27px;display:flex;align-items:center;padding:4px 7px;margin-bottom:6px;
    border:1px inset #fff;background:#ffffe1;color:#333;white-space:nowrap;overflow:hidden;text-overflow:ellipsis
}
.toolbar{overflow-x:auto;overflow-y:hidden;flex:0 0 auto}
.toolbar .tool{flex:0 0 auto}
.client-window.compact .workspace,.client-window.compact .toolbar{display:none}
.connect-window.compact .connect-body,.connect-window.compact .menu-bar,.connect-window.compact .statusbar{display:none}

</style>
</head>
<body>

<div id="landing">
  <div class="classic-window connect-window">
    <div class="titlebar">
      <div class="caption"><span class="app-glyph"></span> xsukax RetroIRC Client — Connection Center</div>
      <div class="win-buttons"><button class="win-btn" id="landingMin" type="button" title="Minimize panel">_</button><button class="win-btn" id="landingMax" type="button" title="Toggle panel width">□</button><button class="win-btn" id="landingClose" type="button" title="Reset connection form">×</button></div>
    </div>
    <div class="menu-bar">
      <span class="menu-item" id="landingFile" tabindex="0">File</span><span class="menu-item" id="landingServers" tabindex="0">Servers</span><span class="menu-item" id="landingOptions" tabindex="0">Options</span><span class="menu-item" id="landingHelp" tabindex="0">Help</span>
    </div>
    <div class="connect-body">
      <div class="hero">
        <div class="hero-card">
          <h1>Welcome to xsukax RetroIRC Client</h1>
          <p>A Python-powered IRC client with a classic MSN-era room layout and mIRC-style controls.</p>
          <p class="muted">Choose a network, set your nickname and authentication, then connect. Server and port fields remain editable.</p>
        </div>
        <div class="tip-card">
          <strong>Connection tip</strong>
          <p>TLS is preferred when the network offers it. Port <b>6697</b> is the conventional IRC-over-TLS port; classic plaintext IRC commonly uses <b>6667</b>.</p>
        </div>
      </div>

      <fieldset id="serverSection">
        <legend>1. Choose an IRC network</legend>
        <div class="server-grid" id="serverGrid"></div>
      </fieldset>

      <fieldset id="connectionSection">
        <legend>2. Connection &amp; identity</legend>
        <div class="form-grid">
          <label for="serverHost">Server:</label>
          <input id="serverHost" class="wide-field" autocomplete="off">
          <label for="serverPort">Port:</label>
          <input id="serverPort" type="number" min="1" max="65535">

          <label for="primaryNick">Primary nickname:</label>
          <input id="primaryNick" maxlength="30" value="" placeholder="xRetroGuest###">
          <label for="realName">Real name / label:</label>
          <input id="realName" maxlength="80" value="xsukax RetroIRC Client User">

          <label for="altNicks">Alternative nicknames:</label>
          <input id="altNicks" class="span3" maxlength="240" value="" placeholder="Alternative nicknames are generated automatically">

          <label></label>
          <div class="span3 checkbox-row">
            <input type="checkbox" id="useTls">
            <label for="useTls" style="text-align:left">Use TLS / SSL encrypted connection</label>
          </div>

          <label></label>
          <div class="span3 checkbox-row">
            <input type="checkbox" id="autoReconnect" checked>
            <label for="autoReconnect" style="text-align:left">Automatically reconnect if the connection drops</label>
          </div>

          <label></label>
          <div class="span3 checkbox-row">
            <input type="checkbox" id="autoRejoin" checked>
            <label for="autoRejoin" style="text-align:left">Rejoin open rooms after reconnect</label>
          </div>
        </div>

        <div class="auth-box">
          <div class="checkbox-row">
            <input type="checkbox" id="registeredUser">
            <label for="registeredUser"><b>I am a registered user of this IRC network</b></label>
          </div>
          <div id="authDetails" style="display:none;margin-top:9px">
            <div class="auth-grid">
              <label for="authMode">Authentication:</label>
              <select id="authMode">
                <option value="nickserv">NickServ IDENTIFY</option>
                <option value="sasl">SASL PLAIN</option>
                <option value="serverpass">Server PASS</option>
                <option value="undernet">Undernet X login</option>
                <option value="quakenet">QuakeNet Q AUTH</option>
                <option value="gamesurge">GameSurge AuthServ</option>
              </select>

              <label for="accountName">Account / username:</label>
              <input id="accountName" autocomplete="username" placeholder="Blank = use primary nickname">

              <label for="accountPassword">Password:</label>
              <input id="accountPassword" type="password" autocomplete="current-password">

              <label></label>
              <div class="muted">Passwords are used only by the live PHP connection process and are not sent back to browser chat logs.</div>
            </div>
          </div>
        </div>

        <div id="connectError"></div>
        <div class="connect-actions">
          <button type="button" id="resetBtn">Reset</button>
          <button type="button" id="connectBtn"><b>Connect to IRC</b></button>
        </div>
      </fieldset>
    </div>
    <div class="statusbar">
      <div class="statuscell flex">Ready. Select a server or choose Custom Server.</div>
      <div class="statuscell">xsukax RetroIRC Client 2.1.3 Python</div>
    </div>
  </div>
</div>

<div id="client">
  <div class="classic-window client-window">
    <div class="titlebar">
      <div class="caption"><span class="app-glyph"></span> <span id="windowTitle">xsukax RetroIRC Client</span></div>
      <div class="win-buttons"><button class="win-btn" id="clientMin" type="button" title="Minimize client panel">_</button><button class="win-btn" id="clientMax" type="button" title="Toggle client size">□</button><button class="win-btn" id="topDisconnect" type="button" title="Disconnect and return">×</button></div>
    </div>
    <div class="toolbar">
      <button class="tool" id="disconnectBtn" type="button" title="Disconnect and return to Connection Center">Disconnect</button>
      <button class="tool" id="reconnectBtn" type="button" title="Reconnect the current IRC session">Reconnect</button>
      <span class="sep"></span>
      <button class="tool" id="joinBtn" type="button">Join Room</button>
      <button class="tool" id="partBtn" type="button">Leave Room</button>
      <button class="tool" id="roomsBtn" type="button">Room List</button>
      <button class="tool" id="peopleToggleBtn" type="button" aria-expanded="false" title="Show or hide people in this room">People</button>
      <span class="sep"></span>
      <button class="tool" id="nickBtn" type="button">Nickname</button>
      <button class="tool" id="whoisBtn" type="button">WhoIs</button>
      <button class="tool" id="propsBtn" type="button">Room Settings</button>
      <span class="sep"></span>
      <button class="tool" id="rawBtn" type="button">Raw</button>
      <button class="tool" id="saveLogBtn" type="button">Save Log</button>
      <span class="sep"></span>
      <button class="tool" id="helpBtn" type="button" title="Open client help">Help</button>
    </div>

    <div class="workspace">
      <aside class="navpane">
        <div class="navhead">Chat Rooms</div>
        <div class="tree" id="tree"></div>
      </aside>

      <main class="roomarea">
        <div class="tabstrip" id="tabs"></div>
        <div class="room-banner">
          <div class="room-title" id="roomTitle">Status</div>
          <div class="room-topic" id="roomTopic">IRC connection messages and notices appear here.</div>
        </div>

        <div class="room-content">
          <div class="transcript" id="transcript" aria-live="polite"></div>

          <aside class="people">
            <div class="people-head"><div class="people-head-inner"><span>People in this room <span id="peopleCount"></span></span><button id="peopleCloseBtn" type="button" title="Hide people list">×</button></div></div>
            <div class="user-list" id="userList"></div>
            <div class="modbar" id="modbar">
              <button type="button" id="kickBtn">Kick</button>
              <button type="button" id="banBtn">Ban</button>
              <button type="button" id="kickBanBtn">Kick + Ban</button>
              <button type="button" id="userPropsBtn">User</button>
            </div>
            <div class="role-legend" id="roleLegend"></div>
          </aside>
        </div>

        <div class="composer">
          <input id="messageInput" autocomplete="off" placeholder="Type a message or /command…">
          <button id="sendBtn" type="button"><b>Send</b></button>
        </div>
      </main>
    </div>

    <div class="statusbar">
      <div class="statuscell flex" id="connectionStatus">Connecting…</div>
      <div class="statuscell" id="nickStatus">Nick: —</div>
      <div class="statuscell" id="secureStatus">—</div>
    </div>
  </div>
</div>

<!-- Generic prompt dialog -->
<div class="overlay" id="promptOverlay">
  <div class="classic-window dialog" style="width:min(470px,95vw)">
    <div class="titlebar"><span id="promptTitle">Enter value</span><button class="win-btn" id="promptClose" type="button">×</button></div>
    <div class="dialog-body">
      <div id="promptText" style="margin-bottom:7px"></div>
      <input id="promptInput" style="width:100%">
    </div>
    <div class="dialog-actions"><button type="button" id="promptCancel">Cancel</button><button type="button" id="promptOk"><b>OK</b></button></div>
  </div>
</div>

<!-- Room properties dialog -->
<div class="overlay" id="propsOverlay">
  <div class="classic-window dialog">
    <div class="titlebar"><span id="propsTitle">Room Settings</span><button class="win-btn" type="button" data-close="propsOverlay">×</button></div>
    <div class="dialog-body">
      <div class="props-grid">
        <label for="topicField">Room topic:</label>
        <input id="topicField">
        <label>My room role:</label>
        <div id="myRoleLabel">Guest</div>
      </div>

      <fieldset style="margin-top:10px">
        <legend>Common room settings</legend>
        <div class="mode-options">
          <label class="checkbox-row"><input type="checkbox" id="modeI"> Invite only (+i)</label>
          <label class="checkbox-row"><input type="checkbox" id="modeM"> Moderated (+m)</label>
          <label class="checkbox-row"><input type="checkbox" id="modeN"> Block outside messages (+n)</label>
          <label class="checkbox-row"><input type="checkbox" id="modeT"> Host-only topic (+t)</label>
          <label class="checkbox-row"><input type="checkbox" id="modeS"> Secret room (+s)</label>
          <label class="checkbox-row"><input type="checkbox" id="modeP"> Private room (+p)</label>
        </div>
        <div class="props-grid">
          <label for="modeKey">Room key (+k):</label><input id="modeKey" placeholder="Blank = no key">
          <label for="modeLimit">User limit (+l):</label><input id="modeLimit" type="number" min="0" placeholder="0 = no limit">
        </div>
      </fieldset>

      <fieldset>
        <legend>Advanced room mode</legend>
        <div style="display:flex;gap:6px">
          <input id="advancedMode" style="flex:1" placeholder="+C-c or +f 5:10 (server dependent)">
          <button id="advancedModeBtn" type="button">Send MODE</button>
        </div>
        <div class="muted" style="margin-top:5px">Use this for network-specific modes that do not have a universal graphical control.</div>
      </fieldset>

      <fieldset>
        <legend>Ban list</legend>
        <button type="button" id="refreshBansBtn">Refresh Ban List</button>
        <div class="ban-list" id="banList"></div>
      </fieldset>

      <div class="user-admin">
        <button type="button" id="ownerSelected" data-membership-mode="q">Give Owner (+q)</button>
        <button type="button" id="deownerSelected" data-membership-mode="q">Remove Owner (-q)</button>
        <button type="button" id="adminSelected" data-membership-mode="a">Give Admin (+a)</button>
        <button type="button" id="deadminSelected" data-membership-mode="a">Remove Admin (-a)</button>
        <button type="button" id="opSelected" data-membership-mode="o">Give Operator (+o)</button>
        <button type="button" id="deopSelected" data-membership-mode="o">Remove Operator (-o)</button>
        <button type="button" id="halfopSelected" data-membership-mode="h">Give Half-Op (+h)</button>
        <button type="button" id="dehalfopSelected" data-membership-mode="h">Remove Half-Op (-h)</button>
        <button type="button" id="voiceSelected" data-membership-mode="v">Give Voice (+v)</button>
        <button type="button" id="devoiceSelected" data-membership-mode="v">Remove Voice (-v)</button>
      </div>
    </div>
    <div class="dialog-actions">
      <button type="button" data-close="propsOverlay">Close</button>
      <button type="button" id="applyPropsBtn"><b>Apply Settings</b></button>
    </div>
  </div>
</div>

<!-- Room list dialog -->
<div class="overlay" id="roomsOverlay">
  <div class="classic-window dialog" style="width:min(760px,96vw)">
    <div class="titlebar"><span>Available Rooms</span><button class="win-btn" type="button" data-close="roomsOverlay">×</button></div>
    <div class="dialog-body">
      <div style="display:flex;gap:6px;margin-bottom:7px">
        <input id="roomFilter" style="flex:1" placeholder="Filter room name or topic">
        <button id="refreshRoomsBtn" type="button">Refresh List</button>
      </div>
      <div id="roomListStatus" class="room-list-status">Room list has not been loaded yet.</div>
      <div id="roomListScroll" style="height:420px;overflow:auto;border:2px inset #fff;background:#fff">
        <table class="room-list">
          <thead><tr><th><button class="sort-head" type="button" data-room-sort="name">Room <span data-sort-mark="name"></span></button></th><th><button class="sort-head" type="button" data-room-sort="users">Users <span data-sort-mark="users"></span></button></th><th><button class="sort-head" type="button" data-room-sort="topic">Topic <span data-sort-mark="topic"></span></button></th></tr></thead>
          <tbody id="roomListBody"></tbody>
        </table>
      </div>
    </div>
    <div class="dialog-actions"><button type="button" data-close="roomsOverlay">Close</button></div>
  </div>
</div>

<!-- User right-click context menu -->
<div class="context-menu" id="userContextMenu" role="menu" aria-hidden="true">
  <button type="button" data-user-action="query">Open Private Chat</button>
  <button type="button" data-user-action="whois">WhoIs</button>
  <button type="button" data-user-action="copy">Copy Nickname</button>
  <div class="context-sep"></div>
  <button type="button" data-user-action="kick" data-mod-action="1">Kick</button>
  <button type="button" data-user-action="ban" data-mod-action="1">Ban</button>
  <button type="button" data-user-action="kickban" data-mod-action="1">Kick + Ban</button>
  <div class="context-sep"></div>
  <button type="button" data-user-action="owner" data-mod-action="1" data-membership-mode="q">Give Owner (+q)</button>
  <button type="button" data-user-action="deowner" data-mod-action="1" data-membership-mode="q">Remove Owner (-q)</button>
  <button type="button" data-user-action="admin" data-mod-action="1" data-membership-mode="a">Give Admin (+a)</button>
  <button type="button" data-user-action="deadmin" data-mod-action="1" data-membership-mode="a">Remove Admin (-a)</button>
  <button type="button" data-user-action="op" data-mod-action="1" data-membership-mode="o">Give Operator (+o)</button>
  <button type="button" data-user-action="deop" data-mod-action="1" data-membership-mode="o">Remove Operator (-o)</button>
  <button type="button" data-user-action="halfop" data-mod-action="1" data-membership-mode="h">Give Half-Op (+h)</button>
  <button type="button" data-user-action="dehalfop" data-mod-action="1" data-membership-mode="h">Remove Half-Op (-h)</button>
  <button type="button" data-user-action="voice" data-mod-action="1" data-membership-mode="v">Give Voice (+v)</button>
  <button type="button" data-user-action="devoice" data-mod-action="1" data-membership-mode="v">Remove Voice (-v)</button>
</div>

<!-- Help dialog -->
<div class="overlay" id="helpOverlay">
  <div class="classic-window dialog">
    <div class="titlebar"><span>xsukax RetroIRC Client Help</span><button class="win-btn" type="button" data-close="helpOverlay">×</button></div>
    <div class="dialog-body">
      <p><b>Tabs &amp; people:</b> every room/private-chat tab has an × close button. Right-click a nickname for private chat, WhoIs, copy, and moderation actions when you have room privileges.</p>
      <p><b>Common commands</b></p>
      <div class="help-code">/join #room [key]
/part [#room] [reason]
/nick NewNick
/msg Nick message
/query Nick
/me action text
/notice Nick message
/whois Nick
/mode #room +m
/topic [new topic]
/kick Nick [reason]
/ban Nick
/unban mask
/invite Nick [#room]
/away [message]
/list [pattern]
/raw IRC COMMAND
/clear
/disconnect [reason]</div>
      <p><b>Python-only controls:</b> Reconnect can restore a dropped session, optional auto-rejoin returns to open rooms, Raw sends protocol commands directly, and Save Log exports the current Status/room/private-chat transcript.</p>
      <p><b>Role colors:</b> hammer colors are fixed by IRC membership mode, never by that network's rank count: <b>+q yellow (owner/founder)</b>, <b>+a brown (admin/protected)</b>, <b>+o red (operator)</b>, <b>+h blue (half-op)</b>, <b>+v green (voice)</b>, and <b>gray for ordinary users</b>. A mode is treated as a membership privilege only when the server advertises it in <code>005 PREFIX=(modes)prefixes</code>. ChanServ and other service bots receive the color of their actual advertised channel status.</p>
      <p><b>Mobile layout:</b> on phones, the left navigation is hidden because the closable tab strip already provides room/query switching. The People button opens the user list as an overlay drawer and × hides it again, leaving the full chat width available while typing.</p>
      <p><b>Python service:</b> the browser uses one bidirectional WebSocket to the local xsukax Python service, which owns the IRC TCP/TLS connection. This avoids the long-running PHP worker and command-queue limitations.</p>
      <p><b>Reconnect:</b> Python keeps the IRC socket and browser WebSocket in one asynchronous session. Automatic reconnect and room rejoin can be enabled on the connection page. Reconnect attempts use generation guards and backoff so an older socket cannot start a second overlapping reconnect cycle.</p>
      <p><b>Security note:</b> private/reserved Custom Server targets are blocked by default. Set <code>ALLOW_PRIVATE_IRC=1</code> on the Python service only if LAN access is intentional.</p>
      <p class="muted">MSN-era visual styling is an interface homage only; xsukax RetroIRC Client is not affiliated with Microsoft, mIRC, or any IRC network.</p>
    </div>
    <div class="dialog-actions"><button type="button" data-close="helpOverlay">Close</button></div>
  </div>
</div>

<script>
'use strict';

const SERVER_PRESETS = [{"name":"Libera.Chat","host":"irc.libera.chat","port":6697,"tls":true,"auth":"sasl"},{"name":"OFTC","host":"irc.oftc.net","port":6697,"tls":true,"auth":"sasl"},{"name":"EFnet","host":"irc.efnet.org","port":6697,"tls":true,"auth":"nickserv"},{"name":"Undernet","host":"irc.undernet.org","port":6667,"tls":false,"auth":"undernet"},{"name":"DALnet","host":"irc.dal.net","port":6697,"tls":true,"auth":"nickserv"},{"name":"QuakeNet","host":"irc.quakenet.org","port":6697,"tls":true,"auth":"quakenet"},{"name":"Rizon","host":"irc.rizon.net","port":6697,"tls":true,"auth":"sasl"},{"name":"IRCnet","host":"open.ircnet.net","port":6697,"tls":true,"auth":"nickserv"},{"name":"HybridIRC","host":"irc.hybridirc.com","port":6697,"tls":true,"auth":"sasl"},{"name":"Snoonet","host":"irc.snoonet.org","port":6697,"tls":true,"auth":"sasl"},{"name":"GameSurge","host":"irc.gamesurge.net","port":6667,"tls":false,"auth":"gamesurge"},{"name":"EsperNet","host":"irc.esper.net","port":6697,"tls":true,"auth":"nickserv"},{"name":"freenode","host":"irc.freenode.net","port":6697,"tls":true,"auth":"nickserv"},{"name":"GeekShed","host":"irc.geekshed.net","port":6697,"tls":true,"auth":"nickserv"},{"name":"SwiftIRC","host":"irc.swiftirc.net","port":6697,"tls":true,"auth":"nickserv"}];

const $ = id => document.getElementById(id);
const app = {
  ws: null,
  connected: false,
  connecting: false,
  manualDisconnect: false,
  lastConfig: null,
  reconnectTimer: null,
  reconnectAttempt: 0,
  connectionGeneration: 0,
  pendingRejoin: [],
  nick: '',
  host: '',
  port: 0,
  tls: false,
  current: 'Status',
  selectedUser: null,
  prefixModes: 'qaohv',
  prefixSymbols: '~&@%+',
  buffers: new Map([['Status', []]]),
  channels: new Map(),
  queries: new Map(),
  roomList: new Map(),
  roomListOrder: [],
  roomListPending: [],
  roomListLoading: false,
  roomListFlushTimer: null,
  roomListSort: {key:'users', dir:'desc'},
  banList: new Map(),
  whois: new Map()
};

function ircFold(s) {
  return String(s || '')
    .toLowerCase()
    .replace(/\[/g, '{').replace(/\]/g, '}')
    .replace(/\\/g, '|').replace(/\^/g, '~');
}
function isChannel(name) { return /^[#&+!]/.test(name || ''); }
function escVisible(s) { return String(s ?? ''); }
function timeStamp() {
  return new Date().toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'});
}
function ensureBuffer(name) {
  if (!app.buffers.has(name)) app.buffers.set(name, []);
  return app.buffers.get(name);
}
function addMsg(target, text, cls='') {
  const buf = ensureBuffer(target);
  buf.push({time:timeStamp(), text:String(text), cls});
  if (buf.length > 5000) buf.splice(0, buf.length - 5000);
  if (app.current === target) renderTranscript();
}
function showOverlay(id) { $(id).style.display = 'flex'; }
function hideOverlay(id) { $(id).style.display = 'none'; }
document.addEventListener('click', e => {
  const id = e.target?.dataset?.close;
  if (id) hideOverlay(id);
});

function openPrompt(title, text, initial='') {
  return new Promise(resolve => {
    $('promptTitle').textContent = title;
    $('promptText').textContent = text;
    $('promptInput').value = initial;
    showOverlay('promptOverlay');
    setTimeout(() => { $('promptInput').focus(); $('promptInput').select(); }, 0);

    let done = false;
    const ok = () => finish($('promptInput').value);
    const cancel = () => finish(null);
    const key = ev => {
      if (ev.key === 'Enter') { ev.preventDefault(); ok(); }
      if (ev.key === 'Escape') { ev.preventDefault(); cancel(); }
    };
    const finish = value => {
      if (done) return;
      done = true;
      $('promptOk').removeEventListener('click', ok);
      $('promptCancel').removeEventListener('click', cancel);
      $('promptClose').removeEventListener('click', cancel);
      $('promptInput').removeEventListener('keydown', key);
      hideOverlay('promptOverlay');
      resolve(value);
    };

    $('promptOk').addEventListener('click', ok);
    $('promptCancel').addEventListener('click', cancel);
    $('promptClose').addEventListener('click', cancel);
    $('promptInput').addEventListener('keydown', key);
  });
}

const FIXED_MEMBERSHIP_TYPES = {
  q: {priority:0, label:'Owner / Founder', cssClass:'mode-q'},
  a: {priority:1, label:'Admin / Protected', cssClass:'mode-a'},
  o: {priority:2, label:'Channel Operator', cssClass:'mode-o'},
  h: {priority:3, label:'Half-Operator', cssClass:'mode-h'},
  v: {priority:4, label:'Voice', cssClass:'mode-v'}
};
const EXTRA_MODE_COLORS = ['mode-extra-1','mode-extra-2','mode-extra-3','mode-extra-4'];

function advertisedPrivileges() {
  const out = [];
  const count = Math.min(app.prefixModes.length, app.prefixSymbols.length);
  for (let i = 0; i < count; i++) {
    const mode = app.prefixModes[i];
    const symbol = app.prefixSymbols[i];
    const fixed = FIXED_MEMBERSHIP_TYPES[mode];
    const stableBucket = Math.abs([...mode].reduce((n,ch) => ((n * 33) ^ ch.charCodeAt(0)) >>> 0, 5381)) % EXTRA_MODE_COLORS.length;
    out.push({
      advertisedRank: i,
      priority: fixed ? fixed.priority : 100 + i,
      mode,
      symbol,
      label: fixed ? fixed.label : `Server-specific status +${mode}`,
      cssClass: fixed ? fixed.cssClass : EXTRA_MODE_COLORS[stableBucket]
    });
  }
  return out;
}

function fixedPrivilegeInfo(mode) {
  const fixed = FIXED_MEMBERSHIP_TYPES[mode];
  if (!fixed) return null;
  const symbol = symbolForMode(mode) || ({q:'~',a:'&',o:'@',h:'%',v:'+'}[mode] || '');
  return {priority:fixed.priority, mode, symbol, label:fixed.label, cssClass:fixed.cssClass};
}

function userPrivilege(user) {
  if (!user) return {priority:Number.MAX_SAFE_INTEGER, mode:'', symbol:'', label:'Ordinary User', cssClass:'ordinary'};
  const prefixes = user.prefixes || new Set();
  let best = null;
  for (const info of advertisedPrivileges()) {
    if (!prefixes.has(info.symbol)) continue;
    if (!best || info.priority < best.priority || (info.priority === best.priority && info.advertisedRank < best.advertisedRank)) best = info;
  }
  return best || {priority:Number.MAX_SAFE_INTEGER, mode:'', symbol:'', label:'Ordinary User', cssClass:'ordinary'};
}

function createHammer(privilege) {
  const info = privilege || {label:'Ordinary User', cssClass:'ordinary', mode:'', symbol:''};
  const h = document.createElement('span');
  h.className = `hammer ${info.cssClass}`;
  h.title = info.mode ? `${info.label} (${info.symbol || '?'} / +${info.mode})` : info.label;
  return h;
}

function renderRoleLegend() {
  const box = $('roleLegend');
  if (!box) return;
  box.textContent = '';

  // Always display the same standard color key, even when this IRC network omits a level.
  for (const mode of ['q','a','o','h','v']) {
    const info = fixedPrivilegeInfo(mode);
    const supported = serverSupportsMembershipMode(mode);
    const row = document.createElement('div');
    row.className = 'legend-line' + (supported ? '' : ' legend-unsupported');
    row.appendChild(createHammer(info));
    const text = document.createElement('span');
    text.appendChild(document.createTextNode(`${info.label} `));
    const code = document.createElement('span');
    code.className = 'role-code';
    code.textContent = `${info.symbol || '?'} / +${mode}${supported ? '' : ' (not on this network)'}`;
    text.appendChild(code);
    row.appendChild(text);
    box.appendChild(row);
  }

  // Show any extra network-specific membership prefixes after the fixed standard legend.
  for (const info of advertisedPrivileges().filter(x => !FIXED_MEMBERSHIP_TYPES[x.mode])) {
    const row = document.createElement('div');
    row.className = 'legend-line';
    row.appendChild(createHammer(info));
    row.appendChild(document.createTextNode(`${info.label} ${info.symbol} / +${info.mode}`));
    box.appendChild(row);
  }

  const normal = document.createElement('div');
  normal.className = 'legend-line';
  normal.appendChild(createHammer(null));
  normal.appendChild(document.createTextNode('Ordinary User — no channel status prefix'));
  box.appendChild(normal);
}

function userRole(user) {
  const info = userPrivilege(user);
  return info.mode || 'ordinary';
}
function currentChannel() {
  return app.channels.get(app.current) || null;
}
function myPrivilege(channel=currentChannel()) {
  if (!channel) return userPrivilege(null);
  return userPrivilege(channel.users.get(ircFold(app.nick)));
}
function myRole(channel=currentChannel()) {
  return myPrivilege(channel).label;
}
function canModerate(channel=currentChannel()) {
  const mode = myPrivilege(channel).mode;
  return ['q','a','o','h'].includes(mode);
}
function serverSupportsMembershipMode(mode) {
  return app.prefixModes.includes(mode);
}

function randomGuestNick() {
  let n;
  if (globalThis.crypto && crypto.getRandomValues) {
    const a = new Uint32Array(1);
    crypto.getRandomValues(a);
    n = 100 + (a[0] % 900);
  } else {
    n = 100 + Math.floor(Math.random() * 900);
  }
  return `xRetroGuest${n}`;
}

function setDefaultGuestIdentity() {
  const used = new Set();
  const next = () => {
    let nick;
    do { nick = randomGuestNick(); } while (used.has(nick));
    used.add(nick);
    return nick;
  };
  $('primaryNick').value = next();
  $('altNicks').value = `${next()} ${next()} ${next()}`;
}

async function closeTarget(name) {
  if (!name || name === 'Status') return;
  const wasCurrent = app.current === name;

  if (app.channels.has(name)) {
    await sendRaw(`PART ${name} :Closing room tab`);
    app.channels.delete(name);
  }
  if (app.queries.has(name)) app.queries.delete(name);
  app.buffers.delete(name);

  if (wasCurrent) {
    const channelNames = [...app.channels.keys()];
    const queryNames = [...app.queries.keys()];
    app.current = channelNames.at(-1) || queryNames.at(-1) || 'Status';
  }
  app.selectedUser = null;
  renderAll();
}

function hideUserContextMenu() {
  const menu = $('userContextMenu');
  menu.classList.remove('open');
  menu.setAttribute('aria-hidden', 'true');
}

function showUserContextMenu(ev, nick) {
  ev.preventDefault();
  ev.stopPropagation();
  app.selectedUser = nick;
  renderUsers();

  const menu = $('userContextMenu');
  const canMod = canModerate() && ircFold(nick) !== ircFold(app.nick);
  menu.querySelectorAll('[data-mod-action="1"]').forEach(btn => {
    const membershipMode = btn.dataset.membershipMode || '';
    btn.disabled = !canMod || (membershipMode && !serverSupportsMembershipMode(membershipMode));
  });
  menu.classList.add('open');
  menu.setAttribute('aria-hidden', 'false');

  const margin = 6;
  const rect = menu.getBoundingClientRect();
  const x = Math.max(margin, Math.min(ev.clientX, window.innerWidth - rect.width - margin));
  const y = Math.max(margin, Math.min(ev.clientY, window.innerHeight - rect.height - margin));
  menu.style.left = `${x}px`;
  menu.style.top = `${y}px`;
}

function renderTreeTabs() {
  const tree = $('tree');
  const tabs = $('tabs');
  tree.textContent = '';
  tabs.textContent = '';

  const names = ['Status', ...app.channels.keys(), ...app.queries.keys()];
  for (const name of names) {
    const closable = name !== 'Status';

    const t = document.createElement('div');
    t.className = 'tree-item' + (app.current === name ? ' active' : '');
    const dot = document.createElement('span');
    dot.className = 'dot ' + (name === 'Status' ? 'status' : isChannel(name) ? 'channel' : 'query');
    const lab = document.createElement('span');
    lab.className = 'tree-label';
    lab.textContent = name;
    t.append(dot, lab);
    if (closable) {
      const close = document.createElement('button');
      close.type = 'button';
      close.className = 'tree-close';
      close.title = isChannel(name) ? 'Leave room and close tab' : 'Close private chat';
      close.textContent = '×';
      close.onclick = ev => { ev.stopPropagation(); closeTarget(name); };
      t.appendChild(close);
    }
    t.onclick = () => switchTarget(name);
    tree.appendChild(t);

    const tab = document.createElement('div');
    tab.className = 'tab' + (app.current === name ? ' active' : '');
    const tabLabel = document.createElement('span');
    tabLabel.className = 'tab-label';
    tabLabel.textContent = name;
    tab.appendChild(tabLabel);
    if (closable) {
      const close = document.createElement('button');
      close.type = 'button';
      close.className = 'tab-close';
      close.title = isChannel(name) ? 'Leave room and close tab' : 'Close private chat';
      close.textContent = '×';
      close.onclick = ev => { ev.stopPropagation(); closeTarget(name); };
      tab.appendChild(close);
    }
    tab.onclick = () => switchTarget(name);
    tabs.appendChild(tab);
  }
}

function renderHeader() {
  const ch = currentChannel();
  $('roomTitle').textContent = app.current;
  if (app.current === 'Status') {
    $('roomTopic').textContent = 'IRC connection messages and notices appear here.';
  } else if (ch) {
    $('roomTopic').textContent = ch.topic || 'No room topic is set.';
  } else {
    $('roomTopic').textContent = 'Private conversation';
  }
  $('windowTitle').textContent = app.current === 'Status'
    ? `xsukax RetroIRC Client — ${app.host || 'IRC'}`
    : `${app.current} — xsukax RetroIRC Client`;
}

function renderTranscript() {
  const el = $('transcript');
  const buf = ensureBuffer(app.current);
  const atBottom = el.scrollTop + el.clientHeight >= el.scrollHeight - 24;
  el.textContent = '';

  for (const m of buf) {
    const row = document.createElement('div');
    row.className = 'msg ' + (m.cls || '');
    const ts = document.createElement('span');
    ts.className = 'time';
    ts.textContent = `[${m.time}]`;
    row.appendChild(ts);

    // Highlight leading "<nick>" or "* nick" without ever treating message data as HTML.
    const text = String(m.text);
    const nickMatch = text.match(/^(<[^>]+>|\* [^\s]+)([\s\S]*)$/);
    if (nickMatch) {
      const n = document.createElement('span');
      n.className = 'nick';
      n.textContent = nickMatch[1];
      row.appendChild(n);
      row.appendChild(document.createTextNode(nickMatch[2]));
    } else {
      row.appendChild(document.createTextNode(text));
    }
    el.appendChild(row);
  }
  if (atBottom || buf.length < 50) el.scrollTop = el.scrollHeight;
}

function sortedUsers(ch) {
  return [...ch.users.values()].sort((a,b) => {
    const d = userPrivilege(a).priority - userPrivilege(b).priority;
    return d || a.nick.localeCompare(b.nick, undefined, {sensitivity:'base'});
  });
}
function renderUsers() {
  const list = $('userList');
  list.textContent = '';
  const ch = currentChannel();

  if (!ch) {
    $('peopleCount').textContent = '';
    $('modbar').style.display = 'none';
    return;
  }

  const users = sortedUsers(ch);
  $('peopleCount').textContent = `(${users.length})`;

  for (const u of users) {
    const row = document.createElement('div');
    row.className = 'user-row' + (app.selectedUser && ircFold(app.selectedUser) === ircFold(u.nick) ? ' selected' : '');
    const privilege = userPrivilege(u);
    row.appendChild(createHammer(privilege));
    row.title = [privilege.mode ? `${privilege.label} (${privilege.symbol} / +${privilege.mode})` : privilege.label, u.user && u.host ? `${u.user}@${u.host}` : '', u.away ? 'Away' : ''].filter(Boolean).join(' — ');
    const n = document.createElement('span');
    n.className = 'user-nick';
    n.textContent = u.nick;
    row.appendChild(n);
    row.onclick = () => {
      app.selectedUser = u.nick;
      renderUsers();
    };
    row.ondblclick = () => {
      app.queries.set(u.nick, true);
      switchTarget(u.nick);
    };
    row.oncontextmenu = ev => showUserContextMenu(ev, u.nick);
    list.appendChild(row);
  }

  $('modbar').style.display = canModerate(ch) ? 'flex' : 'none';
}

function renderAll() {
  renderTreeTabs();
  renderHeader();
  renderTranscript();
  renderUsers();
  $('nickStatus').textContent = `Nick: ${app.nick || '—'}`;
  $('secureStatus').textContent = app.tls ? 'TLS' : 'Plain IRC';
  $('partBtn').disabled = !currentChannel();
  $('propsBtn').disabled = !currentChannel();
}

function switchTarget(name) {
  app.current = name;
  if (isPhoneLayout()) setPeopleDrawer(false);
  app.selectedUser = null;
  ensureBuffer(name);
  renderAll();
  $('messageInput').focus();
}

function makeChannel(name) {
  if (!app.channels.has(name)) {
    app.channels.set(name, {
      name,
      topic:'',
      users:new Map(),
      modes:new Set(),
      modeArgs:{},
      bans:[],
      creation:null
    });
    ensureBuffer(name);
  }
  return app.channels.get(name);
}

function ensureUser(ch, nick) {
  const key = ircFold(nick);
  if (!ch.users.has(key)) ch.users.set(key, {nick, prefixes:new Set(), user:'', host:'', away:false});
  const u = ch.users.get(key);
  u.nick = nick;
  return u;
}

function parseIRC(line) {
  let rest = line;
  let tags = {};
  let prefix = '';

  if (rest.startsWith('@')) {
    const sp = rest.indexOf(' ');
    const raw = rest.slice(1, sp);
    rest = rest.slice(sp + 1);
    for (const pair of raw.split(';')) {
      const [k,v=''] = pair.split('=');
      tags[k] = v;
    }
  }
  if (rest.startsWith(':')) {
    const sp = rest.indexOf(' ');
    prefix = rest.slice(1, sp);
    rest = rest.slice(sp + 1);
  }
  let trailing = null;
  const ti = rest.indexOf(' :');
  if (ti >= 0) {
    trailing = rest.slice(ti + 2);
    rest = rest.slice(0, ti);
  }
  const parts = rest.trim().split(/ +/).filter(Boolean);
  const command = (parts.shift() || '').toUpperCase();
  if (trailing !== null) parts.push(trailing);
  const nick = prefix ? prefix.split('!')[0] : '';
  const userHost = prefix.includes('!') ? prefix.slice(prefix.indexOf('!') + 1) : '';
  const [user='', host=''] = userHost.includes('@') ? [userHost.slice(0,userHost.indexOf('@')), userHost.slice(userHost.indexOf('@')+1)] : ['', ''];
  return {tags,prefix,command,params:parts,nick,user,host};
}

function parseNamesToken(token) {
  let t = token;
  const prefixes = new Set();
  while (t && app.prefixSymbols.includes(t[0])) {
    prefixes.add(t[0]);
    t = t.slice(1);
  }
  // userhost-in-names may produce nick!user@host
  let nick = t, user='', host='';
  if (t.includes('!')) {
    nick = t.slice(0,t.indexOf('!'));
    const uh = t.slice(t.indexOf('!')+1);
    if (uh.includes('@')) {
      user = uh.slice(0,uh.indexOf('@'));
      host = uh.slice(uh.indexOf('@')+1);
    }
  }
  return {nick,user,host,prefixes};
}

function symbolForMode(mode) {
  const i = app.prefixModes.indexOf(mode);
  return i >= 0 ? app.prefixSymbols[i] : '';
}

function applyMode(ch, modeString, args, emitText=false) {
  if (!ch || !modeString) return;
  let adding = true, ai = 0;
  const userModeSet = new Set(app.prefixModes.split(''));

  for (const c of modeString) {
    if (c === '+') { adding = true; continue; }
    if (c === '-') { adding = false; continue; }

    const isUserMode = userModeSet.has(c);
    const needsArg = isUserMode || ['b','e','I','k'].includes(c) || (c === 'l' && adding);
    const arg = needsArg ? args[ai++] : null;

    if (isUserMode && arg) {
      const u = ensureUser(ch, arg);
      const sym = symbolForMode(c);
      if (sym) adding ? u.prefixes.add(sym) : u.prefixes.delete(sym);
      continue;
    }

    if (c === 'b' && arg) {
      if (adding) {
        if (!ch.bans.some(x => x.mask === arg)) ch.bans.push({mask:arg,setter:'',time:''});
      } else {
        ch.bans = ch.bans.filter(x => x.mask !== arg);
      }
      continue;
    }

    if (adding) ch.modes.add(c); else ch.modes.delete(c);
    if (c === 'k') {
      if (adding && arg) ch.modeArgs.k = arg;
      if (!adding) delete ch.modeArgs.k;
    }
    if (c === 'l') {
      if (adding && arg) ch.modeArgs.l = arg;
      if (!adding) delete ch.modeArgs.l;
    }
  }

  if (emitText) renderUsers();
}


function isPhoneLayout() {
  return window.matchMedia('(max-width:700px)').matches;
}
function setPeopleDrawer(open) {
  const pane = document.querySelector('.people');
  if (!pane) return;
  if (!isPhoneLayout()) open = false;
  pane.classList.toggle('mobile-open', !!open);
  const btn = $('peopleToggleBtn');
  if (btn) {
    btn.setAttribute('aria-expanded', open ? 'true' : 'false');
    btn.textContent = open ? 'Hide People' : 'People';
  }
}
function togglePeopleDrawer() {
  const pane = document.querySelector('.people');
  setPeopleDrawer(!(pane && pane.classList.contains('mobile-open')));
}

function updateConnectionButtons() {
  const open = app.ws && app.ws.readyState === WebSocket.OPEN;
  $('disconnectBtn').disabled = !open;
  $('reconnectBtn').disabled = app.connecting || !app.lastConfig;
  $('sendBtn').disabled = !open;
}

function currentOpenChannels() {
  return [...app.channels.keys()];
}

function roomListSortText() {
  const label = app.roomListSort.key === 'users' ? 'Users' : app.roomListSort.key === 'name' ? 'Room' : 'Topic';
  return `${label} ${app.roomListSort.dir === 'asc' ? '▲' : '▼'}`;
}

function updateRoomListStatus() {
  const count = app.roomList.size;
  if (app.roomListLoading) {
    $('roomListStatus').textContent = `Loading rooms… ${count.toLocaleString()} received. Display stays in arrival order while loading; ${roomListSortText()} will be applied when complete.`;
  } else if (count) {
    const cap = count > 5000 ? ' · displaying first 5,000 matching rooms' : '';
    $('roomListStatus').textContent = `${count.toLocaleString()} rooms loaded · sorted by ${roomListSortText()}${cap}. Double-click a room to join.`;
  } else {
    $('roomListStatus').textContent = 'Room list has not been loaded yet.';
  }
  $('refreshRoomsBtn').textContent = app.roomListLoading ? 'Restart List' : 'Refresh List';
}

function makeRoomRow(r) {
  const tr = document.createElement('tr');
  tr.dataset.roomName = r.name;
  for (const val of [r.name, String(r.users), r.topic]) {
    const td = document.createElement('td');
    td.textContent = val;
    tr.appendChild(td);
  }
  tr.ondblclick = async () => {
    await sendRaw(`JOIN ${r.name}`);
    hideOverlay('roomsOverlay');
  };
  return tr;
}

function beginRoomList() {
  if (app.roomListFlushTimer) { clearTimeout(app.roomListFlushTimer); app.roomListFlushTimer = null; }
  app.roomList = new Map();
  app.roomListOrder = [];
  app.roomListPending = [];
  app.roomListLoading = true;
  $('roomListBody').textContent = '';
  updateRoomListStatus();
}

function queueRoomListEntry(entry) {
  const key = ircFold(entry.name);
  const existing = app.roomList.get(key);
  if (existing) {
    existing.users = entry.users;
    existing.topic = entry.topic;
    return;
  }
  entry.seq = app.roomListOrder.length;
  app.roomList.set(key, entry);
  app.roomListOrder.push(key);
  app.roomListPending.push(key);
  if (!app.roomListFlushTimer) {
    app.roomListFlushTimer = setTimeout(flushRoomListPending, 120);
  }
}

function flushRoomListPending() {
  app.roomListFlushTimer = null;
  if (!app.roomListPending.length) { updateRoomListStatus(); return; }
  const body = $('roomListBody');
  const filter = $('roomFilter').value.trim().toLowerCase();
  const frag = document.createDocumentFragment();
  for (const key of app.roomListPending.splice(0)) {
    const r = app.roomList.get(key);
    if (!r) continue;
    if (filter && !r.name.toLowerCase().includes(filter) && !r.topic.toLowerCase().includes(filter)) continue;
    if (body.children.length + frag.childNodes.length < 5000) frag.appendChild(makeRoomRow(r));
  }
  body.appendChild(frag);
  updateRoomListStatus();
}

function finishRoomList() {
  if (app.roomListFlushTimer) { clearTimeout(app.roomListFlushTimer); app.roomListFlushTimer = null; }
  app.roomListPending = [];
  app.roomListLoading = false;
  renderRoomList(true);
  updateRoomListStatus();
}

function saveCurrentLog() {
  const buf = ensureBuffer(app.current);
  const lines = buf.map(m => `[${m.time}] ${m.text}`).join('\n');
  const blob = new Blob([lines + (lines ? '\n' : '')], {type:'text/plain;charset=utf-8'});
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `xsukax-${String(app.current).replace(/[^A-Za-z0-9._-]+/g,'_')}-${new Date().toISOString().slice(0,10)}.log`;
  document.body.appendChild(a);
  a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 0);
}

function handleIRC(line) {
  const p = parseIRC(line);
  const c = p.command;
  const a = p.params;

  if (c === 'PING' || c === 'PONG') return;

  if (c === '001') {
    app.nick = a[0] || app.nick;
    app.connected = true;
    $('connectionStatus').textContent = `Connected to ${app.host}:${app.port}`;
    addMsg('Status', a.at(-1) || line, 'system');
    app.reconnectAttempt = 0;
    updateConnectionButtons();
    if (app.pendingRejoin.length) {
      const rooms = [...new Set(app.pendingRejoin)];
      app.pendingRejoin = [];
      setTimeout(() => rooms.forEach(room => sendRaw(`JOIN ${room}`)), 250);
    }
    renderAll();
    return;
  }

  if (c === '005') {
    for (const tok of a.slice(1,-1)) {
      const m = tok.match(/^PREFIX=\(([^)]+)\)(.+)$/);
      if (m) {
        app.prefixModes = m[1];
        app.prefixSymbols = m[2];
        renderRoleLegend();
        renderUsers();
      }
    }
    addMsg('Status', a.at(-1) || line, 'system');
    return;
  }

  if (c === '433') {
    addMsg('Status', 'Nickname is already in use. Trying an alternative if one is configured.', 'error');
    return;
  }

  if (c === 'JOIN') {
    const chan = a[0] || '';
    if (!chan) return;
    const ch = makeChannel(chan);
    const u = ensureUser(ch, p.nick);
    u.user = p.user || u.user;
    u.host = p.host || u.host;

    if (ircFold(p.nick) === ircFold(app.nick)) {
      app.current = chan;
      sendRaw(`MODE ${chan}`);
      sendRaw(`WHO ${chan}`);
      addMsg(chan, `*** You joined ${chan}`, 'join');
    } else {
      addMsg(chan, `*** ${p.nick} joined the room`, 'join');
    }
    renderAll();
    return;
  }

  if (c === 'PART') {
    const chan = a[0] || '';
    const ch = app.channels.get(chan);
    const reason = a[1] ? ` (${a[1]})` : '';
    if (ch) ch.users.delete(ircFold(p.nick));
    if (ircFold(p.nick) === ircFold(app.nick)) {
      addMsg(chan, `*** You left ${chan}${reason}`, 'part');
      app.channels.delete(chan);
      if (app.current === chan) app.current = 'Status';
    } else if (ch) {
      addMsg(chan, `*** ${p.nick} left the room${reason}`, 'part');
    }
    renderAll();
    return;
  }

  if (c === 'QUIT') {
    const reason = a[0] ? ` (${a[0]})` : '';
    for (const [name,ch] of app.channels) {
      if (ch.users.delete(ircFold(p.nick))) addMsg(name, `*** ${p.nick} quit${reason}`, 'part');
    }
    renderUsers();
    return;
  }

  if (c === 'NICK') {
    const newNick = a[0] || '';
    if (!newNick) return;
    const oldNick = p.nick;
    for (const [name,ch] of app.channels) {
      const oldKey = ircFold(oldNick);
      if (ch.users.has(oldKey)) {
        const u = ch.users.get(oldKey);
        ch.users.delete(oldKey);
        u.nick = newNick;
        ch.users.set(ircFold(newNick), u);
        addMsg(name, `*** ${oldNick} is now known as ${newNick}`, 'system');
      }
    }
    if (ircFold(oldNick) === ircFold(app.nick)) app.nick = newNick;
    if (app.queries.has(oldNick)) {
      app.queries.delete(oldNick);
      app.queries.set(newNick, true);
      const oldBuf = app.buffers.get(oldNick);
      if (oldBuf) {
        app.buffers.delete(oldNick);
        app.buffers.set(newNick, oldBuf);
      }
      if (app.current === oldNick) app.current = newNick;
    }
    renderAll();
    return;
  }

  if (c === 'PRIVMSG') {
    const target = a[0] || '';
    let text = a[1] || '';
    let cls = '';
    let display;
    if (text.startsWith('\x01ACTION ') && text.endsWith('\x01')) {
      text = text.slice(8,-1);
      display = `* ${p.nick} ${text}`;
      cls = 'action';
    } else {
      display = `<${p.nick}> ${text}`;
    }
    const out = isChannel(target) ? target : p.nick;
    if (!isChannel(target)) app.queries.set(p.nick, true);
    addMsg(out, display, cls);
    if (app.current !== out) renderTreeTabs();
    return;
  }

  if (c === 'NOTICE') {
    const target = a[0] || '';
    const text = a[1] || '';
    const out = isChannel(target) ? target : 'Status';
    addMsg(out, `-${p.nick || p.prefix}- ${text}`, 'notice');
    return;
  }

  if (c === 'KICK') {
    const chan = a[0] || '', victim = a[1] || '', reason = a[2] || '';
    const ch = app.channels.get(chan);
    if (ch) ch.users.delete(ircFold(victim));
    addMsg(chan, `*** ${victim} was kicked by ${p.nick}${reason ? ` (${reason})` : ''}`, 'part');
    if (ircFold(victim) === ircFold(app.nick)) {
      app.channels.delete(chan);
      if (app.current === chan) app.current = 'Status';
    }
    renderAll();
    return;
  }

  if (c === 'TOPIC') {
    const chan = a[0] || '';
    const topic = a[1] || '';
    const ch = makeChannel(chan);
    ch.topic = topic;
    addMsg(chan, `*** ${p.nick} changed the topic to: ${topic}`, 'system');
    renderHeader();
    return;
  }

  if (c === 'MODE') {
    const target = a[0] || '';
    const mode = a[1] || '';
    if (isChannel(target)) {
      const ch = makeChannel(target);
      applyMode(ch, mode, a.slice(2), true);
      addMsg(target, `*** ${p.nick || p.prefix} sets mode ${[mode,...a.slice(2)].join(' ')}`, 'system');
      renderUsers();
      if ($('propsOverlay').style.display === 'flex' && target === app.current) populateProps();
    } else {
      addMsg('Status', `*** MODE ${target} ${[mode,...a.slice(2)].join(' ')}`, 'system');
    }
    return;
  }

  // NAMES list
  if (c === '353') {
    const chan = a[2] || '';
    const names = a[3] || '';
    const ch = makeChannel(chan);
    for (const tok of names.split(/ +/)) {
      if (!tok) continue;
      const info = parseNamesToken(tok);
      const u = ensureUser(ch, info.nick);
      u.prefixes = info.prefixes;
      if (info.user) u.user = info.user;
      if (info.host) u.host = info.host;
    }
    renderUsers();
    return;
  }
  if (c === '366') {
    const chan = a[1] || '';
    if (chan) {
      sendRaw(`WHO ${chan}`);
      renderUsers();
    }
    return;
  }

  // WHO reply: me, channel, user, host, server, nick, flags, ...
  if (c === '352') {
    const chan = a[1] || '', user = a[2] || '', host = a[3] || '', nick = a[5] || '', flags = a[6] || '';
    const ch = app.channels.get(chan);
    if (ch && nick) {
      const u = ensureUser(ch, nick);
      u.user = user;
      u.host = host;
      u.away = flags.includes('G');
      for (const sym of app.prefixSymbols) if (flags.includes(sym)) u.prefixes.add(sym);
    }
    renderUsers();
    return;
  }

  // Topic numeric
  if (c === '332') {
    const chan = a[1] || '', topic = a[2] || '';
    const ch = makeChannel(chan);
    ch.topic = topic;
    renderHeader();
    return;
  }
  if (c === '331') {
    const chan = a[1] || '';
    const ch = makeChannel(chan);
    ch.topic = '';
    renderHeader();
    return;
  }

  // Channel modes numeric
  if (c === '324') {
    const chan = a[1] || '', mode = a[2] || '';
    const ch = makeChannel(chan);
    ch.modes.clear();
    ch.modeArgs = {};
    applyMode(ch, mode, a.slice(3), true);
    if ($('propsOverlay').style.display === 'flex' && chan === app.current) populateProps();
    return;
  }
  if (c === '329') {
    const chan = a[1] || '';
    const ch = makeChannel(chan);
    ch.creation = a[2] || null;
    return;
  }

  // Ban list
  if (c === '367') {
    const chan = a[1] || '', mask = a[2] || '', setter = a[3] || '', when = a[4] || '';
    const ch = makeChannel(chan);
    if (!ch.bans.some(x => x.mask === mask)) ch.bans.push({mask,setter,time:when});
    if (chan === app.current) renderBanList();
    return;
  }
  if (c === '368') {
    if ((a[1] || '') === app.current) renderBanList();
    return;
  }

  // /LIST - keep the table stable while the server is still streaming entries.
  if (c === '321') {
    beginRoomList();
    return;
  }
  if (c === '322') {
    const name = a[1] || '';
    if (name) queueRoomListEntry({name, users:Number(a[2] || 0), topic:a[3] || ''});
    return;
  }
  if (c === '323') {
    finishRoomList();
    addMsg('Status', `Room list received: ${app.roomList.size} rooms.`, 'system');
    return;
  }

  // WHOIS numerics
  if (['311','312','313','317','319','330','671'].includes(c)) {
    const nick = a[1] || '';
    const text = {
      '311': () => `${nick}: ${a[2] || ''}@${a[3] || ''} — ${a[5] || ''}`,
      '312': () => `${nick}: server ${a[2] || ''} — ${a[3] || ''}`,
      '313': () => `${nick}: IRC operator`,
      '317': () => `${nick}: idle ${a[2] || '0'} seconds`,
      '319': () => `${nick}: channels ${a[2] || ''}`,
      '330': () => `${nick}: logged in as ${a[2] || ''}`,
      '671': () => `${nick}: using a secure connection`
    }[c]();
    addMsg('Status', text, 'system');
    return;
  }
  if (c === '318') return;

  // Useful numeric errors/notices.
  if (/^\d{3}$/.test(c)) {
    const numeric = Number(c);
    const text = a.at(-1) || line;
    const cls = numeric >= 400 ? 'error' : 'system';
    addMsg('Status', `[${c}] ${text}`, cls);
    return;
  }

  if (c === 'ERROR') {
    addMsg('Status', `ERROR: ${a[0] || line}`, 'error');
    return;
  }

  addMsg('Status', line, 'system');
}

async function sendRaw(command) {
  command = String(command || '').replace(/[\r\n\0]+/g, ' ').trim();
  if (!command) return false;
  if (!app.ws || app.ws.readyState !== WebSocket.OPEN) {
    addMsg('Status', '*** Not connected to the Python IRC bridge.', 'error');
    return false;
  }
  try {
    app.ws.send(JSON.stringify({type:'command', command}));
    return true;
  } catch (e) {
    addMsg('Status', `*** ${e.message}`, 'error');
    return false;
  }
}

async function disconnect(reason='Leaving xsukax RetroIRC Client') {
  app.manualDisconnect = true;
  if (app.reconnectTimer) { clearTimeout(app.reconnectTimer); app.reconnectTimer = null; }
  app.pendingRejoin = [];

  // Invalidate callbacks from every previous socket before closing the current one.
  // This prevents a delayed close event from an old reconnect attempt from starting
  // another reconnect cycle after the user has already disconnected.
  app.connectionGeneration += 1;
  const ws = app.ws;
  app.ws = null;
  if (ws) {
    if (ws.readyState === WebSocket.OPEN) {
      try { ws.send(JSON.stringify({type:'quit', reason})); } catch {}
      await new Promise(r => setTimeout(r, 80));
    }
    if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
      try { ws.close(1000, 'client disconnect'); } catch {}
    }
  }
  app.connected = false;
  app.connecting = false;
  $('connectionStatus').textContent = 'Disconnected';
  addMsg('Status', '*** Disconnected.', 'part');
  updateConnectionButtons();
}

async function disconnectAndReturn(reason='Leaving xsukax RetroIRC Client') {
  await disconnect(reason);

  // Cancel any delayed reconnect and discard the old room/query UI so the next
  // connection always starts from a clean Connection Center state.
  if (app.reconnectTimer) { clearTimeout(app.reconnectTimer); app.reconnectTimer = null; }
  if (app.roomListFlushTimer) { clearTimeout(app.roomListFlushTimer); app.roomListFlushTimer = null; }
  app.pendingRejoin = [];
  app.reconnectAttempt = 0;
  app.selectedUser = null;
  app.current = 'Status';
  app.buffers = new Map([['Status', []]]);
  app.channels = new Map();
  app.queries = new Map();
  app.roomList = new Map();
  app.roomListOrder = [];
  app.roomListPending = [];
  app.roomListLoading = false;
  app.connected = false;
  app.connecting = false;

  hideUserContextMenu();
  document.querySelectorAll('.overlay').forEach(el => { el.style.display = 'none'; });
  document.querySelector('.client-window')?.classList.remove('compact');
  $('client').classList.remove('restored');
  $('client').style.display = 'none';
  $('landing').style.display = 'block';
  $('connectError').style.display = 'none';
  $('connectBtn').disabled = false;
  $('connectBtn').textContent = 'Connect to IRC';
  window.scrollTo({top:0, behavior:'auto'});
  setTimeout(() => $('connectBtn').focus(), 0);
}

async function reconnectNow() {
  if (!app.lastConfig || app.connecting || app.manualDisconnect) return;
  const rejoin = app.lastConfig.autoRejoin ? currentOpenChannels() : [];
  app.pendingRejoin = rejoin;

  // Invalidate and detach the previous socket first. Its eventual onclose callback
  // is intentionally ignored by the generation checks in connectWithConfig().
  app.connectionGeneration += 1;
  const old = app.ws;
  app.ws = null;
  if (old) {
    try { old.close(1000, 'reconnect replaced'); } catch {}
  }
  await connectWithConfig({...app.lastConfig}, true);
}

function scheduleReconnect() {
  if (app.manualDisconnect || !app.lastConfig?.autoReconnect || app.reconnectTimer || app.connecting || app.connected) return;
  app.reconnectAttempt += 1;

  // A calmer backoff prevents reconnect storms while still recovering quickly from
  // a short network interruption. Add a little jitter so many clients do not all
  // reconnect to an IRC network at exactly the same instant.
  const base = Math.min(90000, 4000 * Math.pow(1.8, Math.min(app.reconnectAttempt - 1, 6)));
  const delay = Math.round(base * (0.90 + Math.random() * 0.20));
  const generationWhenScheduled = app.connectionGeneration;
  $('connectionStatus').textContent = `Disconnected — reconnecting in ${Math.ceil(delay/1000)}s…`;
  addMsg('Status', `*** Connection lost. Automatic reconnect attempt ${app.reconnectAttempt} is scheduled.`, 'error');
  app.reconnectTimer = setTimeout(() => {
    app.reconnectTimer = null;
    if (app.manualDisconnect || app.connected || app.connecting || app.connectionGeneration !== generationWhenScheduled) return;
    reconnectNow();
  }, delay);
}

async function commandInput(raw) {
  raw = raw.trim();
  if (!raw) return;

  if (!raw.startsWith('/')) {
    if (app.current === 'Status') {
      addMsg('Status', 'Join a room or open a private query before sending a normal message.', 'error');
      return;
    }
    await sendRaw(`PRIVMSG ${app.current} :${raw}`);
    addMsg(app.current, `<${app.nick}> ${raw}`, 'self');
    return;
  }

  const space = raw.indexOf(' ');
  const cmd = raw.slice(1, space < 0 ? undefined : space).toLowerCase();
  const rest = space < 0 ? '' : raw.slice(space + 1).trim();
  const parts = rest.split(/ +/).filter(Boolean);

  switch (cmd) {
    case 'join': {
      let chan = parts[0] || '';
      if (chan && !isChannel(chan)) chan = '#' + chan;
      if (!chan) return;
      await sendRaw(`JOIN ${chan}${parts[1] ? ' ' + parts[1] : ''}`);
      break;
    }
    case 'part': {
      let chan = currentChannel()?.name || '';
      let reason = '';
      if (parts[0] && isChannel(parts[0])) {
        chan = parts[0];
        reason = rest.slice(parts[0].length).trim();
      } else reason = rest;
      if (chan) await sendRaw(`PART ${chan}${reason ? ' :' + reason : ''}`);
      break;
    }
    case 'nick':
      if (parts[0]) await sendRaw(`NICK ${parts[0]}`);
      break;
    case 'msg': {
      const target = parts.shift();
      const text = target ? rest.slice(target.length).trim() : '';
      if (target && text) {
        await sendRaw(`PRIVMSG ${target} :${text}`);
        if (!isChannel(target)) app.queries.set(target, true);
        addMsg(target, `<${app.nick}> ${text}`, 'self');
        renderTreeTabs();
      }
      break;
    }
    case 'query': {
      const target = parts[0];
      if (target) {
        app.queries.set(target, true);
        switchTarget(target);
      }
      break;
    }
    case 'me':
      if (app.current !== 'Status' && rest) {
        await sendRaw(`PRIVMSG ${app.current} :\x01ACTION ${rest}\x01`);
        addMsg(app.current, `* ${app.nick} ${rest}`, 'action self');
      }
      break;
    case 'notice': {
      const target = parts.shift();
      const text = target ? rest.slice(target.length).trim() : '';
      if (target && text) await sendRaw(`NOTICE ${target} :${text}`);
      break;
    }
    case 'whois':
      if (parts[0]) await sendRaw(`WHOIS ${parts[0]}`);
      break;
    case 'mode':
      if (rest) await sendRaw(`MODE ${rest}`);
      else if (currentChannel()) await sendRaw(`MODE ${app.current}`);
      break;
    case 'topic':
      if (currentChannel()) {
        if (rest) await sendRaw(`TOPIC ${app.current} :${rest}`);
        else await sendRaw(`TOPIC ${app.current}`);
      }
      break;
    case 'kick': {
      if (!currentChannel() || !parts[0]) break;
      const victim = parts.shift();
      const reason = parts.join(' ') || 'Removed by room host';
      await sendRaw(`KICK ${app.current} ${victim} :${reason}`);
      break;
    }
    case 'ban':
      if (currentChannel() && parts[0]) await banUser(parts[0], false);
      break;
    case 'unban':
      if (currentChannel() && parts[0]) await sendRaw(`MODE ${app.current} -b ${parts[0]}`);
      break;
    case 'invite': {
      if (!parts[0]) break;
      const chan = parts[1] || currentChannel()?.name;
      if (chan) await sendRaw(`INVITE ${parts[0]} ${chan}`);
      break;
    }
    case 'away':
      await sendRaw(rest ? `AWAY :${rest}` : 'AWAY');
      break;
    case 'list':
      beginRoomList();
      await sendRaw(rest ? `LIST ${rest}` : 'LIST');
      showOverlay('roomsOverlay');
      break;
    case 'raw':
    case 'quote':
      if (rest) await sendRaw(rest);
      break;
    case 'clear':
      app.buffers.set(app.current, []);
      renderTranscript();
      break;
    case 'disconnect':
    case 'quit':
      await disconnect(rest || 'Leaving xsukax RetroIRC Client');
      break;
    default:
      addMsg('Status', `Unknown command: /${cmd}. Open Help for supported shortcuts, or use /raw.`, 'error');
  }
}

async function banUser(nick, kickAfter=false) {
  const ch = currentChannel();
  if (!ch || !canModerate(ch)) return;
  const u = ch.users.get(ircFold(nick));
  let mask = `${nick}!*@*`;
  if (u?.user && u?.host) mask = `*!${u.user}@${u.host}`;
  await sendRaw(`MODE ${ch.name} +b ${mask}`);
  if (kickAfter) await sendRaw(`KICK ${ch.name} ${nick} :Removed by room host`);
}

function selectedNickOrWarn() {
  if (!app.selectedUser) {
    addMsg(app.current, '*** Select a person in the user list first.', 'error');
    return null;
  }
  if (ircFold(app.selectedUser) === ircFold(app.nick)) {
    addMsg(app.current, '*** Select another person for this moderation action.', 'error');
    return null;
  }
  return app.selectedUser;
}

function populateProps() {
  const ch = currentChannel();
  if (!ch) return;
  $('propsTitle').textContent = `Room Settings — ${ch.name}`;
  $('topicField').value = ch.topic || '';
  const mine = myPrivilege(ch);
  $('myRoleLabel').textContent = mine.mode ? `${mine.label} (${mine.symbol} / +${mine.mode})` : mine.label;
  $('modeI').checked = ch.modes.has('i');
  $('modeM').checked = ch.modes.has('m');
  $('modeN').checked = ch.modes.has('n');
  $('modeT').checked = ch.modes.has('t');
  $('modeS').checked = ch.modes.has('s');
  $('modeP').checked = ch.modes.has('p');
  $('modeKey').value = ch.modeArgs.k || '';
  $('modeLimit').value = ch.modeArgs.l || '';
  const allowed = canModerate(ch);
  for (const id of ['topicField','modeI','modeM','modeN','modeT','modeS','modeP','modeKey','modeLimit','advancedMode','advancedModeBtn','applyPropsBtn']) {
    $(id).disabled = !allowed;
  }
  document.querySelectorAll('#propsOverlay [data-membership-mode]').forEach(btn => {
    btn.disabled = !allowed || !serverSupportsMembershipMode(btn.dataset.membershipMode || '');
  });
  renderBanList();
}

function renderBanList() {
  const el = $('banList');
  el.textContent = '';
  const ch = currentChannel();
  if (!ch || !ch.bans.length) {
    const empty = document.createElement('div');
    empty.className = 'muted';
    empty.style.padding = '6px';
    empty.textContent = 'No bans loaded.';
    el.appendChild(empty);
    return;
  }
  for (const ban of ch.bans) {
    const row = document.createElement('div');
    row.className = 'ban-row';
    const text = document.createElement('span');
    text.textContent = ban.mask;
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.textContent = 'Unban';
    btn.disabled = !canModerate(ch);
    btn.onclick = async () => {
      await sendRaw(`MODE ${ch.name} -b ${ban.mask}`);
      ch.bans = ch.bans.filter(x => x.mask !== ban.mask);
      renderBanList();
    };
    row.append(text, btn);
    el.appendChild(row);
  }
}

async function applyProps() {
  const ch = currentChannel();
  if (!ch || !canModerate(ch)) return;

  const pairs = [
    ['i','modeI'],['m','modeM'],['n','modeN'],['t','modeT'],['s','modeS'],['p','modeP']
  ];
  let plus='', minus='';
  for (const [mode,id] of pairs) {
    const desired = $(id).checked;
    const current = ch.modes.has(mode);
    if (desired && !current) plus += mode;
    if (!desired && current) minus += mode;
  }
  if (plus) await sendRaw(`MODE ${ch.name} +${plus}`);
  if (minus) await sendRaw(`MODE ${ch.name} -${minus}`);

  const newKey = $('modeKey').value.trim();
  const oldKey = ch.modeArgs.k || '';
  if (newKey && newKey !== oldKey) await sendRaw(`MODE ${ch.name} +k ${newKey}`);
  if (!newKey && oldKey) await sendRaw(`MODE ${ch.name} -k ${oldKey}`);

  const lim = Math.max(0, Number($('modeLimit').value || 0) || 0);
  const oldLim = Number(ch.modeArgs.l || 0);
  if (lim && lim !== oldLim) await sendRaw(`MODE ${ch.name} +l ${lim}`);
  if (!lim && oldLim) await sendRaw(`MODE ${ch.name} -l`);

  const topic = $('topicField').value;
  if (topic !== ch.topic) await sendRaw(`TOPIC ${ch.name} :${topic}`);

  await sendRaw(`MODE ${ch.name}`);
  hideOverlay('propsOverlay');
}

function renderRoomList(forceSorted=false) {
  const body = $('roomListBody');
  const scroll = $('roomListScroll');
  const oldTop = scroll ? scroll.scrollTop : 0;
  body.textContent = '';
  const f = $('roomFilter').value.trim().toLowerCase();
  const {key, dir} = app.roomListSort;
  const factor = dir === 'asc' ? 1 : -1;
  let rows = [...app.roomList.values()].filter(x => !f || x.name.toLowerCase().includes(f) || x.topic.toLowerCase().includes(f));

  // Stability rule: during LIST streaming, keep arrival order. Sorting is queued and
  // applied atomically when numeric 323 (End of /LIST) arrives.
  if (!app.roomListLoading || forceSorted) {
    rows.sort((a,b) => {
      let d;
      if (key === 'users') d = (a.users - b.users) * factor;
      else d = String(a[key] || '').localeCompare(String(b[key] || ''), undefined, {sensitivity:'base'}) * factor;
      return d || a.seq - b.seq;
    });
  } else {
    rows.sort((a,b) => a.seq - b.seq);
  }

  const frag = document.createDocumentFragment();
  for (const r of rows.slice(0, 5000)) frag.appendChild(makeRoomRow(r));
  body.appendChild(frag);

  document.querySelectorAll('[data-sort-mark]').forEach(mark => {
    mark.textContent = mark.dataset.sortMark === key ? (dir === 'asc' ? '▲' : '▼') : '';
  });
  if (scroll) scroll.scrollTop = oldTop;
  updateRoomListStatus();
}

function setRoomListSort(key) {
  if (!['name','users','topic'].includes(key)) return;
  if (app.roomListSort.key === key) app.roomListSort.dir = app.roomListSort.dir === 'asc' ? 'desc' : 'asc';
  else {
    app.roomListSort.key = key;
    app.roomListSort.dir = key === 'users' ? 'desc' : 'asc';
  }
  if (app.roomListLoading) {
    document.querySelectorAll('[data-sort-mark]').forEach(mark => {
      mark.textContent = mark.dataset.sortMark === app.roomListSort.key ? (app.roomListSort.dir === 'asc' ? '▲' : '▼') : '';
    });
    updateRoomListStatus();
  } else {
    renderRoomList(true);
  }
}

function buildServers() {
  const grid = $('serverGrid');
  grid.textContent = '';
  SERVER_PRESETS.forEach((s,i) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'server-card';
    b.dataset.index = i;
    const strong = document.createElement('strong');
    strong.textContent = s.name;
    const small = document.createElement('small');
    small.textContent = `${s.host}:${s.port}${s.tls ? ' · TLS' : ''}`;
    b.append(strong, small);
    b.onclick = () => selectServer(i);
    grid.appendChild(b);
  });
  const custom = document.createElement('button');
  custom.type = 'button';
  custom.className = 'server-card custom';
  custom.dataset.index = 'custom';
  const strong = document.createElement('strong');
  strong.textContent = 'Custom Server';
  const small = document.createElement('small');
  small.textContent = 'Enter any public IRC host and port';
  custom.append(strong,small);
  custom.onclick = () => selectServer('custom');
  grid.appendChild(custom);
}

function selectServer(index) {
  document.querySelectorAll('.server-card').forEach(x => x.classList.toggle('active', String(x.dataset.index) === String(index)));
  if (index === 'custom') {
    $('serverHost').value = '';
    $('serverPort').value = '6697';
    $('useTls').checked = true;
    $('authMode').value = 'nickserv';
    $('serverHost').focus();
    return;
  }
  const s = SERVER_PRESETS[index];
  $('serverHost').value = s.host;
  $('serverPort').value = s.port;
  $('useTls').checked = !!s.tls;
  $('authMode').value = s.auth || 'nickserv';
}

function gatherConnectionConfig() {
  return {
    host: $('serverHost').value.trim(),
    port: Number($('serverPort').value),
    nick: $('primaryNick').value.trim(),
    alts: $('altNicks').value.trim().split(/[\s,;]+/).filter(Boolean),
    realname: $('realName').value.trim(),
    tls: $('useTls').checked,
    registered: $('registeredUser').checked,
    authMode: $('authMode').value,
    account: $('accountName').value.trim(),
    password: $('accountPassword').value,
    autoReconnect: $('autoReconnect').checked,
    autoRejoin: $('autoRejoin').checked
  };
}

function resetClientState(config, preserveTabs=false) {
  app.nick = config.nick;
  app.host = config.host;
  app.port = config.port;
  app.tls = config.tls;
  if (!preserveTabs) {
    app.buffers = new Map([['Status', []]]);
    app.channels = new Map();
    app.queries = new Map();
    app.current = 'Status';
  } else {
    for (const ch of app.channels.values()) ch.users.clear();
  }
  app.roomList = new Map();
  app.roomListOrder = [];
  app.roomListPending = [];
  app.roomListLoading = false;
  app.roomListSort = {key:'users', dir:'desc'};
  app.selectedUser = null;
}

async function connectWithConfig(config, reconnecting=false) {
  const err = $('connectError');
  err.style.display = 'none';
  if (app.connecting) return;
  if (!config.host || !config.port || !config.nick) {
    err.textContent = 'Server, port, and nickname are required.';
    err.style.display = 'block';
    return;
  }
  if (config.registered && !config.password) {
    err.textContent = 'Registered-user login is enabled, but no password was entered.';
    err.style.display = 'block';
    return;
  }

  app.connecting = true;
  app.manualDisconnect = false;
  app.lastConfig = {...config, alts:[...config.alts]};
  $('connectBtn').disabled = true;
  $('connectBtn').textContent = reconnecting ? 'Reconnecting…' : 'Connecting…';
  updateConnectionButtons();

  const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const url = `${scheme}//${location.host}/ws`;
  let clientStarted = reconnecting || $('client').style.display === 'block';

  // Every connection attempt gets a monotonically increasing generation. Handlers
  // from any older WebSocket immediately become inert, eliminating overlapping
  // reconnect attempts and the false "Connection setup timed out" cycle they caused.
  const generation = ++app.connectionGeneration;
  const isCurrent = ws => app.connectionGeneration === generation && app.ws === ws && !app.manualDisconnect;

  try {
    const ws = new WebSocket(url);
    app.ws = ws;

    ws.onopen = () => {
      if (!isCurrent(ws)) {
        try { ws.close(1000, 'stale connection'); } catch {}
        return;
      }
      try {
        ws.send(JSON.stringify({type:'connect', config}));
      } catch (e) {
        addMsg('Status', `*** Unable to send connection setup: ${e.message}`, 'error');
        try { ws.close(); } catch {}
      }
    };

    ws.onmessage = ev => {
      if (!isCurrent(ws)) return;
      let m;
      try { m = JSON.parse(ev.data); } catch { return; }
      if (m.type === 'irc') {
        try { handleIRC(m.line || ''); } catch (e) { console.error(e); }
        return;
      }
      if (m.type === 'meta') {
        if (m.event === 'socket-open') {
          if (!clientStarted) resetClientState(config, false);
          else if (reconnecting) resetClientState(config, true);
          clientStarted = true;
          $('landing').style.display = 'none';
          $('client').style.display = 'block';
          $('connectionStatus').textContent = `Socket open to ${m.host}:${m.port}; registering on IRC…`;
          addMsg('Status', `*** Connected socket to ${m.host}:${m.port}${m.tls ? ' using TLS' : ''}.`, 'system');
          app.connecting = false;
          updateConnectionButtons();
          renderAll();
        } else if (m.event === 'nick-fallback') {
          app.nick = m.nick;
          addMsg('Status', `*** Trying alternative nickname: ${m.nick}`, 'system');
          renderAll();
        } else if (m.event === 'auth') {
          addMsg('Status', `*** ${m.message}`, m.ok === false ? 'error' : 'system');
        } else if (m.message) {
          addMsg('Status', `*** ${m.message}`, 'system');
        }
        return;
      }
      if (m.type === 'error') {
        const message = m.message || 'IRC connection error.';
        if (!clientStarted) {
          err.textContent = message;
          err.style.display = 'block';
        } else {
          addMsg('Status', `*** ${message}`, 'error');
          $('connectionStatus').textContent = 'Connection error';
        }
        return;
      }
      if (m.type === 'closed') {
        addMsg('Status', `*** ${m.message || 'IRC connection closed.'}`, 'part');
      }
    };

    ws.onerror = () => {
      if (!isCurrent(ws)) return;
      if (!clientStarted) {
        err.textContent = 'Unable to reach the xsukax Python WebSocket service.';
        err.style.display = 'block';
      }
    };

    ws.onclose = () => {
      // The most important reconnect guard: an older socket is not allowed to alter
      // current state, clear app.connecting, or schedule another retry.
      if (app.connectionGeneration !== generation || app.ws !== ws) return;

      const wasManual = app.manualDisconnect;
      app.connected = false;
      app.connecting = false;
      app.ws = null;
      $('connectBtn').disabled = false;
      $('connectBtn').textContent = 'Connect to IRC';
      updateConnectionButtons();
      if (clientStarted && !wasManual) scheduleReconnect();
    };
  } catch (e) {
    if (app.connectionGeneration === generation) {
      app.connecting = false;
      err.textContent = e.message;
      err.style.display = 'block';
      updateConnectionButtons();
    }
  } finally {
    if (app.connectionGeneration === generation && !app.connecting) {
      $('connectBtn').disabled = false;
      $('connectBtn').textContent = 'Connect to IRC';
    }
  }
}

async function connectNow() {
  await connectWithConfig(gatherConnectionConfig(), false);
}

// Landing events
$('landingMin').onclick = () => document.querySelector('.connect-window').classList.toggle('compact');
$('landingMax').onclick = () => {
  const w = document.querySelector('.connect-window');
  w.style.maxWidth = w.style.maxWidth === 'none' ? '1040px' : 'none';
};
$('landingClose').onclick = () => {
  selectServer(0);
  setDefaultGuestIdentity();
  $('registeredUser').checked = false;
  $('accountName').value = '';
  $('accountPassword').value = '';
  $('authDetails').style.display = 'none';
  $('connectError').style.display = 'none';
  document.querySelector('.connect-window').classList.remove('compact');
  window.scrollTo({top:0, behavior:'smooth'});
};
$('clientMin').onclick = () => document.querySelector('.client-window').classList.toggle('compact');
$('clientMax').onclick = () => $('client').classList.toggle('restored');

$('registeredUser').addEventListener('change', () => $('authDetails').style.display = $('registeredUser').checked ? 'block' : 'none');
$('connectBtn').addEventListener('click', connectNow);
$('resetBtn').addEventListener('click', () => {
  selectServer(0);
  setDefaultGuestIdentity();
  $('registeredUser').checked = false;
  $('autoReconnect').checked = true;
  $('autoRejoin').checked = true;
  $('accountName').value = '';
  $('accountPassword').value = '';
  $('authDetails').style.display = 'none';
});
$('landingFile').addEventListener('click', () => {
  $('connectBtn').scrollIntoView({behavior:'smooth', block:'center'});
  $('connectBtn').focus();
});
$('landingServers').addEventListener('click', () => {
  $('serverSection').scrollIntoView({behavior:'smooth', block:'start'});
  const active = document.querySelector('.server-card.active');
  if (active) active.focus();
});
$('landingOptions').addEventListener('click', () => {
  $('connectionSection').scrollIntoView({behavior:'smooth', block:'start'});
  $('primaryNick').focus();
  $('primaryNick').select();
});
$('landingHelp').addEventListener('click', () => showOverlay('helpOverlay'));
for (const id of ['landingFile','landingServers','landingOptions','landingHelp']) {
  $(id).addEventListener('keydown', ev => {
    if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); $(id).click(); }
  });
}

// Main client events
$('sendBtn').addEventListener('click', async () => {
  const v = $('messageInput').value;
  $('messageInput').value = '';
  await commandInput(v);
});
$('messageInput').addEventListener('keydown', async e => {
  if (e.key === 'Enter') {
    e.preventDefault();
    const v = $('messageInput').value;
    $('messageInput').value = '';
    await commandInput(v);
  }
});
$('disconnectBtn').onclick = () => disconnectAndReturn();
$('reconnectBtn').onclick = () => reconnectNow();
$('topDisconnect').onclick = () => disconnectAndReturn();
$('rawBtn').onclick = async () => { const v = await openPrompt('Raw IRC Command', 'Enter a raw IRC protocol command:', ''); if (v) sendRaw(v); };
$('saveLogBtn').onclick = saveCurrentLog;
$('helpBtn').onclick = () => showOverlay('helpOverlay');
$('peopleToggleBtn').onclick = togglePeopleDrawer;
$('peopleCloseBtn').onclick = () => setPeopleDrawer(false);
window.addEventListener('resize', () => { if (!isPhoneLayout()) setPeopleDrawer(false); });
$('joinBtn').onclick = async () => {
  const v = await openPrompt('Join Room', 'Enter a room/channel name (for example #chat):', '#');
  if (v) commandInput(`/join ${v}`);
};
$('partBtn').onclick = () => currentChannel() && commandInput(`/part ${app.current}`);
$('nickBtn').onclick = async () => {
  const v = await openPrompt('Change Nickname', 'Enter your new IRC nickname:', app.nick);
  if (v) commandInput(`/nick ${v}`);
};
$('whoisBtn').onclick = async () => {
  const initial = app.selectedUser || '';
  const v = await openPrompt('WhoIs', 'Enter a nickname to inspect:', initial);
  if (v) commandInput(`/whois ${v}`);
};
$('roomsBtn').onclick = () => { showOverlay('roomsOverlay'); beginRoomList(); sendRaw('LIST'); };
$('refreshRoomsBtn').onclick = () => { beginRoomList(); sendRaw('LIST'); };
$('roomFilter').oninput = () => renderRoomList(!app.roomListLoading);
document.querySelectorAll('[data-room-sort]').forEach(btn => btn.addEventListener('click', () => setRoomListSort(btn.dataset.roomSort)));

$('userContextMenu').addEventListener('click', async ev => {
  const btn = ev.target.closest('[data-user-action]');
  if (!btn || btn.disabled) return;
  const action = btn.dataset.userAction;
  const nick = app.selectedUser;
  hideUserContextMenu();
  if (!nick) return;

  if (action === 'query') {
    app.queries.set(nick, true);
    switchTarget(nick);
  } else if (action === 'whois') {
    sendRaw(`WHOIS ${nick}`);
    switchTarget('Status');
  } else if (action === 'copy') {
    try { await navigator.clipboard.writeText(nick); }
    catch { addMsg('Status', `Nickname: ${nick}`, 'system'); }
  } else if (action === 'kick') {
    const reason = await openPrompt('Kick User', `Reason for removing ${nick}:`, 'Removed by room host');
    if (reason !== null) sendRaw(`KICK ${app.current} ${nick} :${reason || 'Removed by room host'}`);
  } else if (action === 'ban') {
    banUser(nick, false);
  } else if (action === 'kickban') {
    banUser(nick, true);
  } else if (action === 'owner') {
    if (currentChannel() && serverSupportsMembershipMode('q')) sendRaw(`MODE ${app.current} +q ${nick}`);
  } else if (action === 'deowner') {
    if (currentChannel() && serverSupportsMembershipMode('q')) sendRaw(`MODE ${app.current} -q ${nick}`);
  } else if (action === 'admin') {
    if (currentChannel() && serverSupportsMembershipMode('a')) sendRaw(`MODE ${app.current} +a ${nick}`);
  } else if (action === 'deadmin') {
    if (currentChannel() && serverSupportsMembershipMode('a')) sendRaw(`MODE ${app.current} -a ${nick}`);
  } else if (action === 'op') {
    if (currentChannel() && serverSupportsMembershipMode('o')) sendRaw(`MODE ${app.current} +o ${nick}`);
  } else if (action === 'deop') {
    if (currentChannel() && serverSupportsMembershipMode('o')) sendRaw(`MODE ${app.current} -o ${nick}`);
  } else if (action === 'halfop') {
    if (currentChannel() && serverSupportsMembershipMode('h')) sendRaw(`MODE ${app.current} +h ${nick}`);
  } else if (action === 'dehalfop') {
    if (currentChannel() && serverSupportsMembershipMode('h')) sendRaw(`MODE ${app.current} -h ${nick}`);
  } else if (action === 'voice') {
    if (currentChannel() && serverSupportsMembershipMode('v')) sendRaw(`MODE ${app.current} +v ${nick}`);
  } else if (action === 'devoice') {
    if (currentChannel() && serverSupportsMembershipMode('v')) sendRaw(`MODE ${app.current} -v ${nick}`);
  }
});
document.addEventListener('click', ev => { if (!ev.target.closest('#userContextMenu')) hideUserContextMenu(); });
window.addEventListener('blur', hideUserContextMenu);
window.addEventListener('resize', hideUserContextMenu);
document.addEventListener('scroll', hideUserContextMenu, true);

$('propsBtn').onclick = () => {
  if (!currentChannel()) return;
  populateProps();
  sendRaw(`MODE ${app.current}`);
  showOverlay('propsOverlay');
};

$('kickBtn').onclick = async () => {
  const nick = selectedNickOrWarn(); if (!nick) return;
  const reason = await openPrompt('Kick User', `Reason for removing ${nick}:`, 'Removed by room host');
  if (reason !== null) sendRaw(`KICK ${app.current} ${nick} :${reason || 'Removed by room host'}`);
};
$('banBtn').onclick = async () => { const nick = selectedNickOrWarn(); if (nick) banUser(nick,false); };
$('kickBanBtn').onclick = async () => { const nick = selectedNickOrWarn(); if (nick) banUser(nick,true); };
$('userPropsBtn').onclick = () => {
  const nick = selectedNickOrWarn(); if (!nick) return;
  addMsg('Status', `*** Looking up ${nick}…`, 'system');
  sendRaw(`WHOIS ${nick}`);
  switchTarget('Status');
};

$('applyPropsBtn').onclick = applyProps;
$('advancedModeBtn').onclick = async () => {
  const ch = currentChannel(); const m = $('advancedMode').value.trim();
  if (ch && m && canModerate(ch)) { await sendRaw(`MODE ${ch.name} ${m}`); $('advancedMode').value=''; }
};
$('refreshBansBtn').onclick = () => {
  const ch = currentChannel();
  if (ch) { ch.bans = []; renderBanList(); sendRaw(`MODE ${ch.name} +b`); }
};
for (const [id,mode] of [
  ['ownerSelected','+q'],['deownerSelected','-q'],
  ['adminSelected','+a'],['deadminSelected','-a'],
  ['opSelected','+o'],['deopSelected','-o'],
  ['halfopSelected','+h'],['dehalfopSelected','-h'],
  ['voiceSelected','+v'],['devoiceSelected','-v']
]) {
  $(id).onclick = async () => {
    const nick = selectedNickOrWarn(); const ch = currentChannel();
    const modeChar = mode.slice(1);
    if (nick && ch && canModerate(ch) && serverSupportsMembershipMode(modeChar)) await sendRaw(`MODE ${ch.name} ${mode} ${nick}`);
  };
}

buildServers();
selectServer(0);
setDefaultGuestIdentity();
renderRoleLegend();
updateRoomListStatus();
renderAll();
updateConnectionButtons();
</script>
</body>
</html>
"""


def clean_irc_line(value: str, max_bytes: int = 510) -> str:
    value = str(value).replace("\r", " ").replace("\n", " ").replace("\x00", " ").strip()
    raw = value.encode("utf-8", "ignore")[:max_bytes]
    while raw:
        try:
            return raw.decode("utf-8")
        except UnicodeDecodeError:
            raw = raw[:-1]
    return ""


def parse_irc(line: str) -> tuple[str, str, list[str]]:
    rest = line
    prefix = ""
    if rest.startswith("@"):
        pos = rest.find(" ")
        if pos >= 0:
            rest = rest[pos + 1 :]
    if rest.startswith(":"):
        pos = rest.find(" ")
        if pos >= 0:
            prefix = rest[1:pos]
            rest = rest[pos + 1 :]
    trailing = None
    pos = rest.find(" :")
    if pos >= 0:
        trailing = rest[pos + 2 :]
        rest = rest[:pos]
    parts = rest.strip().split()
    command = parts.pop(0).upper() if parts else ""
    if trailing is not None:
        parts.append(trailing)
    return prefix, command, parts


async def resolve_public_addresses(host: str, port: int) -> list[str]:
    host = host.strip().strip("[]")
    if not host or len(host) > 253 or HOST_BAD.search(host):
        raise ValueError("Enter a valid IRC hostname or IP address.")

    try:
        ipaddress.ip_address(host)
        addresses = [host]
    except ValueError:
        try:
            host_ascii = host.encode("idna").decode("ascii")
        except UnicodeError as exc:
            raise ValueError("The IRC hostname is invalid.") from exc
        loop = asyncio.get_running_loop()
        try:
            infos = await loop.getaddrinfo(host_ascii, port, type=socket.SOCK_STREAM)
        except socket.gaierror as exc:
            raise ValueError(f"The IRC hostname could not be resolved: {exc}") from exc
        addresses = []
        for _family, _socktype, _proto, _canon, sockaddr in infos:
            ip = sockaddr[0]
            if ip not in addresses:
                addresses.append(ip)

    if not addresses:
        raise ValueError("The IRC hostname did not resolve to an address.")

    if not ALLOW_PRIVATE_IRC:
        for value in addresses:
            ip = ipaddress.ip_address(value)
            if not ip.is_global:
                raise ValueError("This target resolves to a private, loopback, link-local, or reserved address. Private IRC targets are blocked by default.")
    return addresses


def validate_config(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError("Invalid connection configuration.")
    host = str(raw.get("host", "")).strip().strip("[]")
    try:
        port = int(raw.get("port", 0))
    except (TypeError, ValueError):
        port = 0
    nick = str(raw.get("nick", "")).strip()
    realname = str(raw.get("realname", "")).strip() or f"{APP_NAME} User"
    tls = bool(raw.get("tls", False))
    registered = bool(raw.get("registered", False))
    auth_mode = str(raw.get("authMode", "nickserv")).lower().strip()
    account = str(raw.get("account", "")).strip()
    password = str(raw.get("password", ""))

    if not host or len(host) > 253 or HOST_BAD.search(host):
        raise ValueError("Enter a valid IRC hostname or IP address.")
    if port < 1 or port > 65535:
        raise ValueError("Port must be between 1 and 65535.")
    if not nick or len(nick) > 30 or NICK_BAD.search(nick):
        raise ValueError("Choose a valid IRC nickname (up to 30 characters).")
    if len(realname) > 80:
        realname = realname[:80]
    if auth_mode not in AUTH_MODES:
        auth_mode = "nickserv"
    if registered and not password:
        raise ValueError("Registered-user login is enabled, but no password was entered.")
    if len(password) > 512 or len(account) > 128:
        raise ValueError("Account credentials are too long.")

    alts_raw = raw.get("alts", [])
    if isinstance(alts_raw, str):
        alts_raw = re.split(r"[\s,;]+", alts_raw)
    if not isinstance(alts_raw, list):
        alts_raw = []
    alts: list[str] = []
    seen = {nick.casefold()}
    for item in alts_raw:
        alt = str(item).strip()
        if not alt or len(alt) > 30 or NICK_BAD.search(alt):
            continue
        folded = alt.casefold()
        if folded not in seen:
            seen.add(folded)
            alts.append(alt)
        if len(alts) >= 8:
            break

    return {
        "host": host,
        "port": port,
        "nick": nick,
        "alts": alts,
        "realname": realname,
        "tls": tls,
        "registered": registered,
        "authMode": auth_mode,
        "account": account,
        "password": password,
    }


@dataclass
class IRCSession:
    ws: web.WebSocketResponse
    config: dict[str, Any]
    reader: asyncio.StreamReader | None = None
    writer: asyncio.StreamWriter | None = None
    send_lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    nick: str = ""
    alt_index: int = 0
    identified: bool = False
    sasl_payload_sent: bool = False
    cap_ls: set[str] = field(default_factory=set)
    cap_end_sent: bool = False
    closing: bool = False

    async def ws_send(self, payload: dict[str, Any]) -> None:
        if not self.ws.closed:
            try:
                await self.ws.send_json(payload)
            except (ConnectionResetError, RuntimeError):
                pass

    async def meta(self, event: str, **extra: Any) -> None:
        await self.ws_send({"type": "meta", "event": event, **extra})

    async def error(self, message: str) -> None:
        await self.ws_send({"type": "error", "message": message})

    async def send_irc(self, line: str) -> bool:
        if not self.writer or self.writer.is_closing():
            return False
        line = clean_irc_line(line)
        if not line:
            return False
        async with self.send_lock:
            self.writer.write((line + "\r\n").encode("utf-8", "ignore"))
            try:
                await self.writer.drain()
            except (ConnectionError, BrokenPipeError):
                return False
        return True

    async def connect_socket(self) -> None:
        host = self.config["host"]
        port = self.config["port"]
        addresses = await resolve_public_addresses(host, port)
        tls = self.config["tls"]
        ssl_context = ssl.create_default_context() if tls else None

        async def attempt(address: str, delay: float) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
            # Stagger validated addresses slightly (happy-eyeballs style). This avoids
            # waiting tens of seconds on an unusable IPv6 route before trying IPv4.
            if delay:
                await asyncio.sleep(delay)
            kwargs: dict[str, Any] = {}
            if tls:
                kwargs["ssl"] = ssl_context
                kwargs["server_hostname"] = host
            return await asyncio.wait_for(
                asyncio.open_connection(address, port, **kwargs),
                timeout=IRC_CONNECT_TIMEOUT,
            )

        tasks = [
            asyncio.create_task(attempt(address, min(i * 0.25, 1.5)), name=f"irc-connect-{i}")
            for i, address in enumerate(addresses)
        ]
        errors: list[str] = []
        try:
            while tasks:
                done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                for task in done:
                    tasks.remove(task)
                    try:
                        reader, writer = task.result()
                    except asyncio.CancelledError:
                        continue
                    except Exception as exc:
                        errors.append(str(exc))
                        continue

                    self.reader, self.writer = reader, writer
                    for other in pending:
                        other.cancel()
                    await asyncio.gather(*pending, return_exceptions=True)

                    # TCP keepalive lets the kernel discover silently broken routes while
                    # IRC's normal PING/PONG continues to handle application liveness.
                    sock = writer.get_extra_info("socket")
                    if sock is not None:
                        try:
                            sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
                            if hasattr(socket, "TCP_KEEPIDLE"):
                                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 90)
                            if hasattr(socket, "TCP_KEEPINTVL"):
                                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 30)
                            if hasattr(socket, "TCP_KEEPCNT"):
                                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 4)
                        except OSError:
                            log.debug("Unable to tune TCP keepalive for IRC socket", exc_info=True)
                    return

            detail = errors[-1] if errors else "all validated addresses failed"
            raise ConnectionError(detail)
        finally:
            for task in tasks:
                if not task.done():
                    task.cancel()
            if tasks:
                await asyncio.gather(*tasks, return_exceptions=True)

    async def begin_registration(self) -> None:
        self.nick = self.config["nick"]
        if self.config["registered"] and self.config["authMode"] == "serverpass":
            await self.send_irc("PASS " + self.config["password"])

        # CAP is negotiated for all sessions. multi-prefix and userhost-in-names make
        # owner/host indicators and moderation masks substantially more reliable.
        await self.send_irc("CAP LS 302")
        await self.send_irc("NICK " + self.nick)
        await self.send_irc(f"USER retroirc 0 * :{self.config['realname']}")

    async def finish_cap(self) -> None:
        if not self.cap_end_sent:
            self.cap_end_sent = True
            await self.send_irc("CAP END")

    async def handle_cap(self, params: list[str]) -> None:
        if len(params) < 2:
            return
        sub = params[1].upper()
        if sub == "LS":
            multi = len(params) >= 4 and params[2] == "*"
            caps_text = params[-1] if len(params) >= 3 else ""
            for token in caps_text.split():
                self.cap_ls.add(token.split("=", 1)[0].lower())
            if multi:
                return

            wanted = [c for c in ("multi-prefix", "userhost-in-names", "away-notify", "account-notify") if c in self.cap_ls]
            wants_sasl = self.config["registered"] and self.config["authMode"] == "sasl"
            if wants_sasl:
                if "sasl" in self.cap_ls:
                    wanted.append("sasl")
                else:
                    await self.meta("auth", ok=False, message="This server did not advertise SASL. Connected without SASL authentication.")
            if wanted:
                await self.send_irc("CAP REQ :" + " ".join(wanted))
            else:
                await self.finish_cap()
            return

        if sub == "ACK":
            ack = set((params[-1] if params else "").lower().split())
            if self.config["registered"] and self.config["authMode"] == "sasl" and "sasl" in ack:
                await self.send_irc("AUTHENTICATE PLAIN")
            else:
                await self.finish_cap()
            return

        if sub == "NAK":
            await self.meta("auth", ok=False, message="The server rejected one or more requested IRC capabilities.")
            await self.finish_cap()

    async def handle_server_line(self, line: str) -> None:
        _prefix, command, params = parse_irc(line)

        if command == "PING":
            token = params[0] if params else ""
            await self.send_irc("PONG :" + token)

        if command == "433":
            alts = self.config["alts"]
            if self.alt_index < len(alts):
                self.nick = alts[self.alt_index]
                self.alt_index += 1
                await self.send_irc("NICK " + self.nick)
                await self.meta("nick-fallback", nick=self.nick)
            else:
                await self.meta("nick-exhausted", message="All configured nicknames are in use. Use /nick to try another.")

        if command == "CAP":
            await self.handle_cap(params)

        if command == "421" and any(p.upper() == "CAP" for p in params):
            # Legacy server with no CAP support; registration can continue normally.
            self.cap_end_sent = True

        if command == "AUTHENTICATE" and self.config["registered"] and self.config["authMode"] == "sasl" and not self.sasl_payload_sent:
            if params and params[0] == "+":
                auth_user = self.config["account"] or self.nick
                payload = base64.b64encode(("\0" + auth_user + "\0" + self.config["password"]).encode()).decode()
                for start in range(0, len(payload), 400):
                    await self.send_irc("AUTHENTICATE " + payload[start : start + 400])
                if len(payload) % 400 == 0:
                    await self.send_irc("AUTHENTICATE +")
                self.sasl_payload_sent = True

        if command == "903":
            await self.meta("auth", ok=True, message="SASL authentication succeeded.")
            await self.finish_cap()
        elif command in {"904", "905", "906", "907"}:
            await self.meta("auth", ok=False, message="SASL authentication failed.")
            await self.finish_cap()

        if command == "001" and self.config["registered"] and not self.identified:
            mode = self.config["authMode"]
            account = self.config["account"] or self.nick
            password = self.config["password"]
            if mode == "nickserv":
                await self.send_irc(f"PRIVMSG NickServ :IDENTIFY {account} {password}")
                self.identified = True
                await self.meta("auth", ok=None, message="NickServ identification sent.")
            elif mode == "undernet":
                await self.send_irc(f"PRIVMSG X@channels.undernet.org :login {account} {password}")
                self.identified = True
                await self.meta("auth", ok=None, message="Undernet X login sent.")
            elif mode == "quakenet":
                await self.send_irc(f"AUTH {account} {password}")
                self.identified = True
                await self.meta("auth", ok=None, message="QuakeNet Q authentication sent.")
            elif mode == "gamesurge":
                await self.send_irc(f"PRIVMSG AuthServ :AUTH {account} {password}")
                self.identified = True
                await self.meta("auth", ok=None, message="GameSurge AuthServ authentication sent.")

    async def irc_reader(self) -> None:
        assert self.reader is not None
        while not self.closing:
            try:
                raw = await self.reader.readline()
            except (ConnectionError, asyncio.IncompleteReadError):
                break
            if not raw:
                break
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            if not line:
                continue
            await self.handle_server_line(line)
            await self.ws_send({"type": "irc", "line": line})
        if not self.closing:
            await self.ws_send({"type": "closed", "message": "IRC server closed the connection."})

    async def browser_reader(self) -> None:
        async for msg in self.ws:
            if msg.type == WSMsgType.TEXT:
                try:
                    data = json.loads(msg.data)
                except json.JSONDecodeError:
                    await self.error("Invalid WebSocket command payload.")
                    continue
                kind = data.get("type")
                if kind == "command":
                    command = clean_irc_line(str(data.get("command", "")))
                    if command:
                        await self.send_irc(command)
                elif kind == "quit":
                    reason = clean_irc_line(str(data.get("reason", "Leaving xsukax RetroIRC Client")), 300)
                    await self.send_irc("QUIT :" + (reason or "Leaving xsukax RetroIRC Client"))
                    self.closing = True
                    return
                elif kind == "ping":
                    await self.ws_send({"type": "meta", "event": "pong"})
            elif msg.type in {WSMsgType.CLOSE, WSMsgType.CLOSED, WSMsgType.ERROR}:
                return

    async def run(self) -> None:
        await self.connect_socket()
        assert self.writer is not None
        peer = self.writer.get_extra_info("peername")
        await self.meta(
            "socket-open",
            host=self.config["host"],
            port=self.config["port"],
            tls=self.config["tls"],
            nick=self.nick or self.config["nick"],
            peer=str(peer[0]) if peer else "",
        )
        await self.begin_registration()

        irc_task = asyncio.create_task(self.irc_reader(), name="irc-reader")
        browser_task = asyncio.create_task(self.browser_reader(), name="browser-reader")
        done, pending = await asyncio.wait({irc_task, browser_task}, return_when=asyncio.FIRST_COMPLETED)
        self.closing = True
        for task in pending:
            task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        await asyncio.gather(*done, return_exceptions=True)

    async def close(self) -> None:
        self.closing = True
        if self.writer and not self.writer.is_closing():
            self.writer.close()
            try:
                await self.writer.wait_closed()
            except Exception:
                pass


def origin_allowed(request: web.Request) -> bool:
    if ALLOW_CROSS_ORIGIN:
        return True
    origin = request.headers.get("Origin")
    if not origin:
        return True
    try:
        return urlsplit(origin).netloc.casefold() == request.host.casefold()
    except ValueError:
        return False


async def index(request: web.Request) -> web.Response:
    return web.Response(
        text=HTML,
        content_type="text/html",
        charset="utf-8",
        headers={
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "same-origin",
            "X-Frame-Options": "SAMEORIGIN",
        },
    )


async def health(request: web.Request) -> web.Response:
    return web.json_response({"ok": True, "app": APP_NAME, "version": VERSION, "irc_connect_timeout": IRC_CONNECT_TIMEOUT, "ws_setup_timeout": WS_SETUP_TIMEOUT, "ws_heartbeat": WS_HEARTBEAT})


async def websocket_handler(request: web.Request) -> web.StreamResponse:
    if not origin_allowed(request):
        raise web.HTTPForbidden(text="Cross-origin WebSocket requests are not allowed.")

    ws = web.WebSocketResponse(heartbeat=WS_HEARTBEAT, receive_timeout=None, max_msg_size=65536, autoping=True)
    await ws.prepare(request)
    session: IRCSession | None = None
    try:
        try:
            first = await asyncio.wait_for(ws.receive(), timeout=WS_SETUP_TIMEOUT)
        except asyncio.TimeoutError:
            await ws.send_json({"type": "error", "message": "Browser connection setup timed out before an IRC configuration was received."})
            return ws
        if first.type != WSMsgType.TEXT:
            await ws.send_json({"type": "error", "message": "A connection configuration was expected."})
            return ws
        try:
            payload = json.loads(first.data)
            if payload.get("type") != "connect":
                raise ValueError("The first WebSocket message must be a connect request.")
            config = validate_config(payload.get("config"))
        except (json.JSONDecodeError, ValueError) as exc:
            await ws.send_json({"type": "error", "message": str(exc)})
            return ws

        session = IRCSession(ws=ws, config=config)
        try:
            await session.run()
        except asyncio.CancelledError:
            raise
        except (ValueError, ConnectionError, OSError, ssl.SSLError, asyncio.TimeoutError) as exc:
            log.info("IRC connection failed for %s:%s: %s", config["host"], config["port"], exc)
            await session.error(f"Connection failed: {exc}")
        except Exception:
            log.exception("Unexpected IRC session error")
            await session.error("Unexpected server-side IRC session error.")
    finally:
        if session:
            await session.close()
        if not ws.closed:
            await ws.close()
    return ws


def create_app() -> web.Application:
    app = web.Application(client_max_size=128 * 1024)
    app.router.add_get("/", index)
    app.router.add_get("/healthz", health)
    app.router.add_get("/ws", websocket_handler)
    return app


if __name__ == "__main__":
    log.info("Starting %s %s on %s:%s", APP_NAME, VERSION, BIND, PORT)
    web.run_app(create_app(), host=BIND, port=PORT, access_log=None, print=None)

PYAPP_XSUKAX_EOF_V214_STABILITY
chmod 0755 "$APP_FILE"
python3 -m py_compile "$APP_FILE"

# The config file is preserved on upgrades unless explicit environment values are supplied.
if [[ ! -f "$CONFIG_FILE" ]]; then
  cat > "$CONFIG_FILE" <<'EOF_CONFIG'
XSUKAX_BIND=127.0.0.1
XSUKAX_PORT=8785
ALLOW_PRIVATE_IRC=0
ALLOW_CROSS_ORIGIN=0
LOG_LEVEL=INFO
# Connection-stability tuning. Defaults are intentionally tolerant of slow/mobile links.
XSUKAX_IRC_CONNECT_TIMEOUT=35
XSUKAX_WS_SETUP_TIMEOUT=120
XSUKAX_WS_HEARTBEAT=60
EOF_CONFIG
fi

# Version 2.1.4 keeps the fixed q/a/o/h/v colors and responsive UI, and hardens connection/reconnect stability.
# Migrate only the old untouched default; explicitly customized ports are preserved.
if [[ -z "${XSUKAX_PORT:-}" ]] && grep -q '^XSUKAX_PORT=8080$' "$CONFIG_FILE"; then
  sed -i 's/^XSUKAX_PORT=8080$/XSUKAX_PORT=8785/' "$CONFIG_FILE"
fi

# Environment variables passed to the installer intentionally override stored values.
set_config() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$CONFIG_FILE"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$CONFIG_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$CONFIG_FILE"
  fi
}
[[ -n "${XSUKAX_BIND:-}" ]] && set_config XSUKAX_BIND "$XSUKAX_BIND"
[[ -n "${XSUKAX_PORT:-}" ]] && set_config XSUKAX_PORT "$XSUKAX_PORT"
[[ -n "${ALLOW_PRIVATE_IRC:-}" ]] && set_config ALLOW_PRIVATE_IRC "$ALLOW_PRIVATE_IRC"
[[ -n "${ALLOW_CROSS_ORIGIN:-}" ]] && set_config ALLOW_CROSS_ORIGIN "$ALLOW_CROSS_ORIGIN"
[[ -n "${LOG_LEVEL:-}" ]] && set_config LOG_LEVEL "$LOG_LEVEL"
[[ -n "${XSUKAX_IRC_CONNECT_TIMEOUT:-}" ]] && set_config XSUKAX_IRC_CONNECT_TIMEOUT "$XSUKAX_IRC_CONNECT_TIMEOUT"
[[ -n "${XSUKAX_WS_SETUP_TIMEOUT:-}" ]] && set_config XSUKAX_WS_SETUP_TIMEOUT "$XSUKAX_WS_SETUP_TIMEOUT"
[[ -n "${XSUKAX_WS_HEARTBEAT:-}" ]] && set_config XSUKAX_WS_HEARTBEAT "$XSUKAX_WS_HEARTBEAT"

# Existing installations may not yet have the new stability keys. Add them without
# changing any values the administrator has already chosen.
for pair in   "XSUKAX_IRC_CONNECT_TIMEOUT=35"   "XSUKAX_WS_SETUP_TIMEOUT=120"   "XSUKAX_WS_HEARTBEAT=60"; do
  key=${pair%%=*}; value=${pair#*=}
  grep -q "^${key}=" "$CONFIG_FILE" || printf '%s=%s\n' "$key" "$value" >> "$CONFIG_FILE"
done
chmod 0644 "$CONFIG_FILE"

cat > "$SERVICE_FILE" <<'EOF_SERVICE'
[Unit]
Description=xsukax RetroIRC Client Python Service
Documentation=https://localhost/
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
DynamicUser=yes
WorkingDirectory=/opt/xsukax-retroirc
EnvironmentFile=-/etc/default/xsukax-retroirc
ExecStart=/usr/bin/python3 /opt/xsukax-retroirc/app.py
Restart=on-failure
RestartSec=2
TimeoutStopSec=8
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
ProcSubset=pid
RestrictSUIDSGID=yes
RestrictRealtime=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
CapabilityBoundingSet=
AmbientCapabilities=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
EOF_SERVICE
chmod 0644 "$SERVICE_FILE"

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  systemctl daemon-reload
  systemctl enable --now xsukax-retroirc.service
  sleep 1
  if ! systemctl is-active --quiet xsukax-retroirc.service; then
    echo "Service failed to start. Recent log output:" >&2
    journalctl -u xsukax-retroirc.service -n 40 --no-pager >&2 || true
    exit 1
  fi
  echo
  echo "$APP_NAME installed and running."
  echo "Service: systemctl status xsukax-retroirc"
else
  echo
  echo "$APP_NAME installed, but systemd is not active in this environment."
  echo "Start it manually with: set -a; source $CONFIG_FILE; set +a; python3 $APP_FILE"
fi

BIND_VALUE=$(awk -F= '$1=="XSUKAX_BIND"{print $2}' "$CONFIG_FILE" | tail -n1)
PORT_VALUE=$(awk -F= '$1=="XSUKAX_PORT"{print $2}' "$CONFIG_FILE" | tail -n1)
[[ -z "$PORT_VALUE" ]] && PORT_VALUE=8785
if [[ "$BIND_VALUE" == "127.0.0.1" || "$BIND_VALUE" == "localhost" ]]; then
  echo "Open: http://127.0.0.1:${PORT_VALUE}/"
else
  echo "Open: http://<this-server-IP>:${PORT_VALUE}/"
fi
echo "Configuration: $CONFIG_FILE"
echo "Application:   $APP_FILE"
echo
 echo "To uninstall: sudo bash $0 --uninstall"
