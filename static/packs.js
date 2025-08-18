document.addEventListener("DOMContentLoaded", ()=>{
  const forms = document.querySelectorAll(".open-pack-form");
  const pre = document.getElementById("preopen");
  forms.forEach(f=>{
    f.addEventListener("submit", (e)=>{
      if(!pre) return;
      e.preventDefault();
      pre.classList.add("show");
      setTimeout(()=> f.submit(), 900);
    });
  });

  const stage = document.querySelector(".pack-stage");
  const hasCards = stage && stage.querySelector(".cards");
  if(stage && hasCards){
    if(stage.classList.contains("reveal")){
      stage.classList.remove("reveal");
      // force reflow
      // eslint-disable-next-line no-unused-expressions
      stage.offsetHeight;
    }
    setTimeout(()=> stage.classList.add("reveal"), 50);
  }

  document.querySelectorAll(".card3d").forEach(card=>{
    card.setAttribute("tabindex","0");
    card.addEventListener("click", ()=> card.classList.toggle("flip"));
    card.addEventListener("keydown", e=>{
      if(e.key===" "||e.key==="Enter"){
        e.preventDefault();
        card.classList.toggle("flip");
      }
    });
  });
});
