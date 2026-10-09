const csrfToken = document.querySelector("meta[name='csrf-token']").content;
const ticket = new URLSearchParams(location.hash.slice(1)).get("ticket");
if (ticket) {
  history.replaceState(null, "", location.pathname);
  fetch("/session/ticket", {
    method: "POST", headers: {"x-csrf-token": csrfToken},
    body: new URLSearchParams({ticket})
  }).then(async response => {
    if (response.ok) location.replace("/");
    else {
      const message = document.createElement("p");
      message.setAttribute("role", "alert");
      message.textContent = await response.text();
      document.querySelector("main").append(message);
    }
  });
}
document.addEventListener("click", event => {
  const control = event.target.closest("[data-confirm]");
  if (control && !window.confirm(control.dataset.confirm)) {
    event.preventDefault();
    event.stopImmediatePropagation();
  }
}, true);
const DesktopHook = {
  mounted() {
    this.canvas = this.el.querySelector("canvas");
    this.surfaces = {};
    this.handleEvent("desktop-frame", frame => {
      if (!frame.width) return;
      this.canvas.width = frame.width; this.canvas.height = frame.height;
      this.surfaces = {1: this.canvas};
      for (const [id, data] of Object.entries(frame.surfaces)) {
        if (id === "1") continue;
        const surface = document.createElement("canvas"); surface.width=data.w; surface.height=data.h;
        if (data.pixels) {
          const bytes=atob(data.pixels), pixels=new Uint8ClampedArray(bytes.length);
          for(let i=0;i<bytes.length;i+=4){pixels[i]=bytes.charCodeAt(i+2);pixels[i+1]=bytes.charCodeAt(i+1);pixels[i+2]=bytes.charCodeAt(i);pixels[i+3]=bytes.charCodeAt(i+3);}
          surface.getContext("2d").putImageData(new ImageData(pixels,data.w,data.h),0,0);
        }
        this.surfaces[id]=surface;
      }
      const color = n => "#" + (n & 0xffffff).toString(16).padStart(6,"0");
      for (const {op,params:p} of frame.ops) {
        const surface=this.surfaces[p.handle || p.dst]; if(!surface) continue;
        const ctx=surface.getContext("2d");
        if(op==="surface.fill_rect") {ctx.fillStyle=color(p.rgb);ctx.fillRect(p.rect.x,p.rect.y,p.rect.w,p.rect.h);}
        if(op==="surface.line") {ctx.strokeStyle=color(p.rgb);ctx.beginPath();ctx.moveTo(p.x0+.5,p.y0+.5);ctx.lineTo(p.x1+.5,p.y1+.5);ctx.stroke();}
        if(op==="text.draw") {
          ctx.font="10px monospace";ctx.textBaseline="top";
          if(p.bg!=null){ctx.fillStyle=color(p.bg);ctx.fillRect(p.x,p.y,p.text.length*8,10);}
          ctx.fillStyle=color(p.fg);
          [...p.text].forEach((letter,i)=>ctx.fillText(letter,p.x+i*8,p.y));
        }
        if(op==="surface.blit" && this.surfaces[p.src]) {const r=p.dst_rect;ctx.drawImage(this.surfaces[p.src],r.x,r.y,r.w,r.h);}
      }
      this.el.querySelector(".desktop-status").textContent=frame.connected ? "Connected · click the desktop to interact" : "Disconnected · showing the last frame";
    });
    const point=e=>{const r=this.canvas.getBoundingClientRect();return {x:Math.round((e.clientX-r.left)*this.canvas.width/r.width),y:Math.round((e.clientY-r.top)*this.canvas.height/r.height)};};
    this.canvas.onpointerdown=e=>{e.preventDefault();this.canvas.focus();this.canvas.setPointerCapture(e.pointerId);this.pushEvent("desktop-input",{kind:4,button:e.button+1,...point(e)});};
    this.canvas.onpointerup=e=>this.pushEvent("desktop-input",{kind:5,button:e.button+1,...point(e)});
    let last=0;
    this.canvas.onpointermove=e=>{if(Date.now()-last>40){last=Date.now();this.pushEvent("desktop-input",{kind:3,...point(e)});}};
    this.canvas.onkeydown=e=>{
      const keys={Enter:13,Backspace:8,Tab:9,Escape:27,ArrowLeft:1073741904,ArrowRight:1073741903,ArrowUp:1073741906,ArrowDown:1073741905};
      const code=keys[e.key] || (e.key.length===1 ? e.key.codePointAt(0) : null);
      if(code!=null){e.preventDefault();this.pushEvent("desktop-input",{kind:1,code,text:e.key.length===1?e.key:""});}
    };
    this.pushEvent("desktop-ready",{});
  },
  reconnected(){this.pushEvent("desktop-ready",{});}
};
const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
  params: {_csrf_token: csrfToken}, hooks: {Desktop: DesktopHook}
});
liveSocket.connect();
