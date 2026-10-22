/* ============================================================
   AISAB — castellano / valenciano
   Las páginas están escritas en castellano (es lo que carga primero).
   Si el visitante elige valenciano, se traduce cada texto con el
   diccionario de js/valenciano.js (texto en castellano → texto en valenciano)
   y la elección se recuerda en este navegador.
   Uso en JS:  AISAB_IDIOMA.t("Texto en castellano")
   ============================================================ */
(function () {
  var CLAVE = "aisab_idioma";
  var ATRIBUTOS = ["placeholder", "alt", "aria-label", "title"];
  var VA = window.AISAB_VA || {};
  var textosOriginales = new WeakMap();   // nodo de texto → castellano
  var atributosOriginales = new WeakMap(); // elemento → { atributo: castellano }
  var tituloOriginal = document.title;

  function leer() { try { return localStorage.getItem(CLAVE); } catch (e) { return null; } }
  function guardar(v) { try { localStorage.setItem(CLAVE, v); } catch (e) {} }
  function normalizar(s) { return s.replace(/\s+/g, " ").trim(); }

  var idioma = new URLSearchParams(location.search).get("idioma") === "va" ? "va" : (leer() === "va" ? "va" : "es");

  function traducir(es) {
    if (idioma !== "va") return es;
    var n = normalizar(es);
    return Object.prototype.hasOwnProperty.call(VA, n) ? VA[n] : es;
  }

  // conserva los espacios de los extremos del nodo original
  function conEspacios(original, nuevo) {
    var ini = original.match(/^\s*/)[0], fin = original.match(/\s*$/)[0];
    return ini + nuevo + fin;
  }

  function pasarTexto(nodo) {
    if (!textosOriginales.has(nodo)) {
      if (!normalizar(nodo.nodeValue)) return;
      textosOriginales.set(nodo, nodo.nodeValue);
    }
    var original = textosOriginales.get(nodo);
    var nuevo = idioma === "va" ? conEspacios(original, traducir(original)) : original;
    if (nodo.nodeValue !== nuevo) nodo.nodeValue = nuevo;
  }

  function pasarAtributos(el) {
    var guardados = atributosOriginales.get(el);
    ATRIBUTOS.forEach(function (a) {
      if (!el.hasAttribute(a)) return;
      if (!guardados) { guardados = {}; atributosOriginales.set(el, guardados); }
      if (!(a in guardados)) guardados[a] = el.getAttribute(a);
      var nuevo = traducir(guardados[a]);
      if (el.getAttribute(a) !== nuevo) el.setAttribute(a, nuevo);
    });
  }

  function recorrer(raiz) {
    if (raiz.nodeType === 3) { pasarTexto(raiz); return; }
    if (raiz.nodeType !== 1) return;
    if (raiz.closest && raiz.closest("[data-sin-traducir], script, style")) return;
    pasarAtributos(raiz);
    var paseo = document.createTreeWalker(raiz, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
      acceptNode: function (n) {
        if (n.nodeType === 1 && (n.tagName === "SCRIPT" || n.tagName === "STYLE" || n.hasAttribute("data-sin-traducir")))
          return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    var n;
    while ((n = paseo.nextNode())) {
      if (n.nodeType === 3) pasarTexto(n); else pasarAtributos(n);
    }
  }

  function aplicar() {
    document.documentElement.lang = idioma === "va" ? "ca-ES-valencia" : "es";
    document.title = traducir(tituloOriginal);
    recorrer(document.body);
    document.querySelectorAll("[data-idioma]").forEach(function (b) {
      var activo = b.getAttribute("data-idioma") === idioma;
      b.classList.toggle("activo", activo);
      b.setAttribute("aria-pressed", activo ? "true" : "false");
    });
    document.querySelectorAll("select.selector-idioma").forEach(function (s) { s.value = idioma; });
  }

  // lo que se añade después (formularios clonados, paneles) también se traduce
  var vigilante = new MutationObserver(function (cambios) {
    if (idioma !== "va") return;
    vigilante.disconnect();
    cambios.forEach(function (c) {
      if (c.type === "characterData") { textosOriginales.delete(c.target); pasarTexto(c.target); }
      else c.addedNodes.forEach(recorrer);
    });
    observar();
  });
  function observar() { vigilante.observe(document.body, { childList: true, subtree: true }); }

  function cambiar(nuevo) {
    nuevo = nuevo === "va" ? "va" : "es";
    if (nuevo === idioma) return;
    idioma = nuevo;
    guardar(idioma);
    vigilante.disconnect();
    aplicar();
    observar();
    document.dispatchEvent(new CustomEvent("aisab:idioma", { detail: idioma }));
  }

  window.AISAB_IDIOMA = {
    actual: function () { return idioma; },
    t: traducir,
    cambiar: cambiar,
    // para textos que el JS cambia a propósito: olvida el castellano guardado
    olvidar: function (el) {
      var paseo = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      var n; while ((n = paseo.nextNode())) textosOriginales.delete(n);
    }
  };

  function arrancar() {
    document.addEventListener("click", function (e) {
      var b = e.target.closest("[data-idioma]");
      if (b) { e.preventDefault(); cambiar(b.getAttribute("data-idioma")); }
    });
    document.addEventListener("change", function (e) {
      if (e.target.matches("select.selector-idioma")) cambiar(e.target.value);
    });
    aplicar();
    observar();
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", arrancar);
  else arrancar();
})();
