use crate::ast::SExpr;
use std::fmt::Write;

pub fn write_scheme(expr: &SExpr) -> String {
    let mut out = String::new();
    write_expr(&mut out, expr);
    out
}

pub fn write_scheme_pretty(expr: &SExpr) -> String {
    let mut out = String::new();
    write_expr_pretty(&mut out, expr, 0);
    out
}

fn write_expr(out: &mut String, expr: &SExpr) {
    match expr {
        SExpr::Void => out.push_str("#void"),
        SExpr::Bool(true) => out.push_str("#t"),
        SExpr::Bool(false) => out.push_str("#f"),
        SExpr::Int(v) => write!(out, "{v}").unwrap(),
        SExpr::Float(v) => write!(out, "{v}").unwrap(),
        SExpr::Str(s) => write!(out, "\"{}\"", escape_str(s)).unwrap(),
        SExpr::Bytes(b) => {
            out.push_str("#b\"");
            for byte in b {
                write!(out, "{:02x}", byte).unwrap();
            }
            out.push('"');
        }
        SExpr::Symbol(s) => out.push_str(s),
        SExpr::Resource(_) => out.push_str("#<resource>"),
        SExpr::List(items) => {
            out.push('(');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(' ');
                }
                write_expr(out, item);
            }
            out.push(')');
        }
        SExpr::Closure { params, body, .. } => {
            out.push_str("(lambda (");
            for (i, p) in params.iter().enumerate() {
                if i > 0 {
                    out.push(' ');
                }
                out.push_str(p);
            }
            out.push_str(") ");
            for (i, b) in body.iter().enumerate() {
                if i > 0 {
                    out.push(' ');
                }
                write_expr(out, b);
            }
            out.push(')');
        }
    }
}

const MAX_WIDTH: usize = 100;

fn write_expr_pretty(out: &mut String, expr: &SExpr, indent: usize) -> usize {
    match expr {
        SExpr::List(items) if !items.is_empty() => {
            let compact = compact_str(expr);
            if indent + compact.len() <= MAX_WIDTH {
                out.push_str(&compact);
                return indent + compact.len();
            }

            out.push('(');
            let head_str = compact_str(&items[0]);
            out.push_str(&head_str);
            let mut col = indent + 1 + head_str.len();
            let child_indent = indent + 2;
            let mut any_broken = false;
            for item in &items[1..] {
                if !any_broken {
                    let ic = compact_str(item);
                    if col + 1 + ic.len() <= MAX_WIDTH {
                        out.push(' ');
                        out.push_str(&ic);
                        col += 1 + ic.len();
                        continue;
                    }
                    any_broken = true;
                }
                out.push('\n');
                for _ in 0..child_indent {
                    out.push(' ');
                }
                col = write_expr_pretty(out, item, child_indent);
            }
            out.push(')');
            col + 1
        }
        _ => {
            let c = compact_str(expr);
            out.push_str(&c);
            indent + c.len()
        }
    }
}

fn compact_str(expr: &SExpr) -> String {
    let mut s = String::new();
    write_expr(&mut s, expr);
    s
}

fn escape_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            _ => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::parse;

    #[test]
    fn round_trip() {
        let cases = [
            "42",
            "-7",
            "3.14",
            "#t",
            "#f",
            "\"hello world\"",
            "(let* ((x 1) (y 2)) (when x y))",
            "(save D1 \"person.age\" (param 2))",
            "(begin (dbg \"x\" 42) (+ 1 2))",
        ];
        for case in cases {
            let parsed = parse(case).unwrap();
            let printed = write_scheme(&parsed);
            let reparsed = parse(&printed).unwrap();
            assert_eq!(parsed, reparsed, "round-trip failed for: {case}");
        }
    }

    #[test]
    fn round_trip_program() {
        let src = "(begin (let* ((D1 (lookup-entity \"person.name\" (param 1)))) (when D1 (save D1 \"person.age\" (param 2)))) (result D1 2))";
        let parsed = parse(src).unwrap();
        let printed = write_scheme(&parsed);
        let reparsed = parse(&printed).unwrap();
        assert_eq!(parsed, reparsed);
    }
}
