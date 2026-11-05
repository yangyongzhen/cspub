/* cspub 官网交互：无依赖、无外部请求，全部渐进增强。
   每个模块都自带兜底——JS 出错时页面内容依然可读（reveal 会全部解除隐藏）。 */
(function () {
  "use strict";

  var docEl = document.documentElement;

  /* ---------- 1. 入场动画 ---------- */
  var revealNodes = [].slice.call(document.querySelectorAll(".reveal"));

  function showAll() {
    revealNodes.forEach(function (el) {
      el.classList.add("is-in");
    });
  }

  function initReveal() {
    if (!("IntersectionObserver" in window)) {
      showAll();
      return;
    }
    // 同一批里轻微错开，避免整屏同时弹起
    var stagger = 0;
    var io = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (!entry.isIntersecting) return;
          var el = entry.target;
          var delay = el.dataset.stagger ? parseInt(el.dataset.stagger, 10) : 0;
          window.setTimeout(function () {
            el.classList.add("is-in");
          }, delay);
          io.unobserve(el);
        });
      },
      { rootMargin: "0px 0px -8% 0px", threshold: 0.08 }
    );
    revealNodes.forEach(function (el) {
      io.observe(el);
      stagger = 0;
    });
  }

  /* ---------- 2. 导航：吸顶状态 + 滚动高亮 + 移动端展开 ---------- */
  var nav = document.getElementById("nav");
  var navLinks = document.getElementById("navLinks");
  var navToggle = document.getElementById("navToggle");

  function setNavState() {
    if (!nav) return;
    nav.classList.toggle("is-stuck", window.scrollY > 8);
  }

  function closeMenu() {
    if (!navLinks || !navToggle) return;
    navLinks.classList.remove("is-open");
    navToggle.setAttribute("aria-expanded", "false");
  }

  if (navToggle && navLinks) {
    navToggle.addEventListener("click", function () {
      var open = navLinks.classList.toggle("is-open");
      navToggle.setAttribute("aria-expanded", open ? "true" : "false");
    });
    // 点链接后收起移动端菜单
    navLinks.addEventListener("click", function (e) {
      if (e.target.closest("a")) closeMenu();
    });
    window.addEventListener("resize", function () {
      if (window.innerWidth > 900) closeMenu();
    });
  }

  // 滚动高亮：取当前视口顶部最近的一个 section
  var sections = [].slice.call(document.querySelectorAll("section[id]"));
  var linkMap = {};
  [].slice.call(document.querySelectorAll(".nav__links a")).forEach(function (a) {
    var id = (a.getAttribute("href") || "").replace("#", "");
    if (id) linkMap[id] = a;
  });

  function spy() {
    if (!sections.length) return;
    var probe = window.scrollY + (window.innerHeight > 720 ? 180 : 120);
    var current = null;
    sections.forEach(function (sec) {
      if (sec.offsetTop <= probe) current = sec.id;
    });
    Object.keys(linkMap).forEach(function (id) {
      linkMap[id].classList.toggle("is-active", id === current);
    });
  }

  /* ---------- 3. 复制按钮 ---------- */
  function copyText(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text);
    }
    // file:// 或无安全上下文时的兜底
    return new Promise(function (resolve, reject) {
      try {
        var ta = document.createElement("textarea");
        ta.value = text;
        ta.setAttribute("readonly", "");
        ta.style.position = "fixed";
        ta.style.top = "-1000px";
        document.body.appendChild(ta);
        ta.select();
        var ok = document.execCommand("copy");
        document.body.removeChild(ta);
        ok ? resolve() : reject(new Error("copy failed"));
      } catch (err) {
        reject(err);
      }
    });
  }

  [].slice.call(document.querySelectorAll(".code__copy")).forEach(function (btn) {
    btn.addEventListener("click", function () {
      var box = btn.closest(".code");
      var pre = box ? box.querySelector("pre") : null;
      if (!pre) return;
      var label = btn.innerHTML;
      copyText(pre.innerText || pre.textContent || "").then(
        function () {
          btn.classList.add("is-done");
          btn.textContent = "已复制";
          window.setTimeout(function () {
            btn.classList.remove("is-done");
            btn.innerHTML = label;
          }, 1600);
        },
        function () {
          btn.textContent = "复制失败";
          window.setTimeout(function () {
            btn.innerHTML = label;
          }, 1600);
        }
      );
    });
  });

  /* ---------- 4. 快速开始的标签页 ---------- */
  var tabs = [].slice.call(document.querySelectorAll(".tab"));
  function selectTab(tab) {
    tabs.forEach(function (t) {
      var on = t === tab;
      t.setAttribute("aria-selected", on ? "true" : "false");
      var panel = document.getElementById(t.getAttribute("aria-controls"));
      if (panel) panel.classList.toggle("is-on", on);
    });
  }

  tabs.forEach(function (tab, i) {
    tab.addEventListener("click", function () {
      selectTab(tab);
    });
    // 左右方向键切换，键盘可用
    tab.addEventListener("keydown", function (e) {
      var next = null;
      if (e.key === "ArrowDown" || e.key === "ArrowRight") next = tabs[(i + 1) % tabs.length];
      if (e.key === "ArrowUp" || e.key === "ArrowLeft") next = tabs[(i - 1 + tabs.length) % tabs.length];
      if (!next) return;
      e.preventDefault();
      selectTab(next);
      next.focus();
    });
  });

  /* ---------- 5. 回到顶部 ---------- */
  var toTop = document.getElementById("toTop");
  if (toTop) {
    toTop.addEventListener("click", function () {
      window.scrollTo({ top: 0, behavior: "smooth" });
    });
  }

  function onScroll() {
    setNavState();
    spy();
    if (toTop) toTop.classList.toggle("is-on", window.scrollY > 640);
  }

  /* ---------- 6. 启动 ---------- */
  try {
    initReveal();
  } catch (err) {
    showAll();
  }
  var ticking = false;
  window.addEventListener(
    "scroll",
    function () {
      if (ticking) return;
      ticking = true;
      window.requestAnimationFrame(function () {
        onScroll();
        ticking = false;
      });
    },
    { passive: true }
  );
  window.addEventListener("load", onScroll);
  docEl.classList.add("js-ready");
  onScroll();
})();
