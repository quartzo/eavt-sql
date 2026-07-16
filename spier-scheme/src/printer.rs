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

fn write_expr_pretty(out: &mut String, expr: &SExpr, indent: usize) {
    match expr {
        SExpr::List(items) if !items.is_empty() && is_long_list(items) => {
            out.push('(');
            write_expr_pretty(out, &items[0], indent + 2);
            for item in &items[1..] {
                out.push('\n');
                for _ in 0..indent + 2 {
                    out.push(' ');
                }
                write_expr_pretty(out, item, indent + 2);
            }
            out.push(')');
        }
        _ => write_expr(out, expr),
    }
}

fn is_long_list(items: &[SExpr]) -> bool {
    items.len() > 3 || items.iter().any(|e| matches!(e, SExpr::List(_) if true))
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
