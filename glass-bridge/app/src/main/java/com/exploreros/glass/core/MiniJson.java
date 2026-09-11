package com.exploreros.glass.core;

import java.util.LinkedHashMap;
import java.util.Map;

/** Small JSON object parser. It rejects trailing data and has bounded caller input. */
public final class MiniJson {
    private MiniJson() { }
    public static Map<String, Object> object(String json) throws ProtocolException {
        Parser p = new Parser(json); Object result = p.value(); p.space();
        if (!(result instanceof Map) || !p.done()) throw new ProtocolException("expected JSON object");
        return cast(result);
    }
    @SuppressWarnings("unchecked") public static Map<String, Object> cast(Object value) { return (Map<String, Object>) value; }
    public static String stringify(Object value) { StringBuilder out = new StringBuilder(); emit(out, value); return out.toString(); }
    private static void emit(StringBuilder out, Object v) {
        if (v == null) { out.append("null"); return; }
        if (v instanceof String) { quote(out, (String) v); return; }
        if (v instanceof Number || v instanceof Boolean) { out.append(v); return; }
        if (v instanceof Map) { out.append('{'); boolean first = true; for (Map.Entry<?, ?> e : ((Map<?, ?>) v).entrySet()) { if (!first) out.append(','); first = false; quote(out, String.valueOf(e.getKey())); out.append(':'); emit(out, e.getValue()); } out.append('}'); return; }
        throw new IllegalArgumentException("unsupported JSON value");
    }
    private static void quote(StringBuilder out, String s) { out.append('"'); for (int i = 0; i < s.length(); i++) { char c = s.charAt(i); if (c == '"' || c == '\\') out.append('\\').append(c); else if (c == '\b') out.append("\\b"); else if (c == '\f') out.append("\\f"); else if (c == '\n') out.append("\\n"); else if (c == '\r') out.append("\\r"); else if (c == '\t') out.append("\\t"); else if (c < 32) { out.append("\\u"); String h = Integer.toHexString(c); for (int j = h.length(); j < 4; j++) out.append('0'); out.append(h); } else out.append(c); } out.append('"'); }
    private static final class Parser {
        private final String s; private int p;
        Parser(String s) { this.s = s == null ? "" : s; }
        boolean done() { return p == s.length(); } void space() { while (p < s.length() && Character.isWhitespace(s.charAt(p))) p++; }
        Object value() throws ProtocolException { space(); if (p >= s.length()) throw bad(); char c = s.charAt(p); if (c == '{') return obj(); if (c == '"') return str(); if (c == 't') return word("true", Boolean.TRUE); if (c == 'f') return word("false", Boolean.FALSE); if (c == 'n') return word("null", null); if (c == '-' || (c >= '0' && c <= '9')) return number(); throw bad(); }
        Object word(String word, Object val) throws ProtocolException { if (!s.regionMatches(p, word, 0, word.length())) throw bad(); p += word.length(); return val; }
        Map<String, Object> obj() throws ProtocolException { Map<String, Object> out = new LinkedHashMap<String, Object>(); p++; space(); if (take('}')) return out; while (true) { space(); if (p >= s.length() || s.charAt(p) != '"') throw bad(); String k = str(); if (out.containsKey(k)) throw new ProtocolException("duplicate JSON key"); space(); if (!take(':')) throw bad(); out.put(k, value()); space(); if (take('}')) return out; if (!take(',')) throw bad(); } }
        String str() throws ProtocolException { if (!take('"')) throw bad(); StringBuilder out = new StringBuilder(); while (p < s.length()) { char c = s.charAt(p++); if (c == '"') return out.toString(); if (c < 32) throw bad(); if (c != '\\') { out.append(c); continue; } if (p >= s.length()) throw bad(); c = s.charAt(p++); if (c == '"' || c == '\\' || c == '/') out.append(c); else if (c == 'b') out.append('\b'); else if (c == 'f') out.append('\f'); else if (c == 'n') out.append('\n'); else if (c == 'r') out.append('\r'); else if (c == 't') out.append('\t'); else if (c == 'u') { if (p + 4 > s.length()) throw bad(); int n = 0; for (int i = 0; i < 4; i++) { int d = Character.digit(s.charAt(p++), 16); if (d < 0) throw bad(); n = (n << 4) | d; } out.append((char) n); } else throw bad(); } throw bad(); }
        Long number() throws ProtocolException { int start = p; if (s.charAt(p) == '-') p++; if (p >= s.length() || s.charAt(p) < '0' || s.charAt(p) > '9') throw bad(); if (s.charAt(p) == '0') p++; else while (p < s.length() && Character.isDigit(s.charAt(p))) p++; if (p < s.length() && (s.charAt(p) == '.' || s.charAt(p) == 'e' || s.charAt(p) == 'E')) throw new ProtocolException("integer required"); try { return Long.valueOf(s.substring(start, p)); } catch (NumberFormatException e) { throw bad(); } }
        boolean take(char c) { if (p < s.length() && s.charAt(p) == c) { p++; return true; } return false; } ProtocolException bad() { return new ProtocolException("malformed JSON"); }
    }
}
