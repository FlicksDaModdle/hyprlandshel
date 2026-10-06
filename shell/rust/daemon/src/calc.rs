//! The launcher's calculator: arithmetic and unit conversion, answered as
//! you type.
//!
//!   12*7.5        2^10 / 3       sqrt(2)*pi       (4+5)%4
//!   15% of 80     5 km in miles  72f in c         3 GB in MiB
//!   90 min in h   2 cups in ml   5 km + 300 m     1.5 kWh in J
//!
//! Command:  calc {id, query}
//! Event:    calc {id, query, result?, exact?}   result is the text to show
//!                                               (and copy); none when the
//!                                               query is not a sum
//!
//! A query that is only a number, or has no operator, unit or function in
//! it, is not answered: "firefox" is not a calculation, and neither is
//! "2048" (that is probably a search).

use crate::out;
use serde_json::{json, Value};
use std::sync::mpsc::{channel, Sender};

#[derive(Clone, Copy, PartialEq, Debug)]
enum Dim {
    Length,
    Mass,
    Time,
    Data,
    Speed,
    Volume,
    Energy,
    Angle,
    Temp,
}

/// A unit: what it measures, and how many base units one of it is (base:
/// metre, kilogram, second, byte, m/s, litre, joule, radian; temperature
/// is handled apart, being offset as well as scaled).
struct Unit {
    names: &'static [&'static str],
    dim: Dim,
    factor: f64,
    show: &'static str,
}

const UNITS: &[Unit] = &[
    Unit { names: &["mm", "millimeter", "millimeters", "millimetre", "millimetres"], dim: Dim::Length, factor: 0.001, show: "mm" },
    Unit { names: &["cm", "centimeter", "centimeters", "centimetre", "centimetres"], dim: Dim::Length, factor: 0.01, show: "cm" },
    Unit { names: &["m", "meter", "meters", "metre", "metres"], dim: Dim::Length, factor: 1.0, show: "m" },
    Unit { names: &["km", "kilometer", "kilometers", "kilometre", "kilometres"], dim: Dim::Length, factor: 1000.0, show: "km" },
    Unit { names: &["in", "inch", "inches", "\""], dim: Dim::Length, factor: 0.0254, show: "in" },
    Unit { names: &["ft", "foot", "feet", "'"], dim: Dim::Length, factor: 0.3048, show: "ft" },
    Unit { names: &["yd", "yard", "yards"], dim: Dim::Length, factor: 0.9144, show: "yd" },
    Unit { names: &["mi", "mile", "miles"], dim: Dim::Length, factor: 1609.344, show: "mi" },
    Unit { names: &["nmi", "nauticalmile", "nauticalmiles"], dim: Dim::Length, factor: 1852.0, show: "nmi" },
    Unit { names: &["mg", "milligram", "milligrams"], dim: Dim::Mass, factor: 1e-6, show: "mg" },
    Unit { names: &["g", "gram", "grams"], dim: Dim::Mass, factor: 0.001, show: "g" },
    Unit { names: &["kg", "kilo", "kilos", "kilogram", "kilograms"], dim: Dim::Mass, factor: 1.0, show: "kg" },
    Unit { names: &["t", "tonne", "tonnes", "ton", "tons"], dim: Dim::Mass, factor: 1000.0, show: "t" },
    Unit { names: &["lb", "lbs", "pound", "pounds"], dim: Dim::Mass, factor: 0.45359237, show: "lb" },
    Unit { names: &["oz", "ounce", "ounces"], dim: Dim::Mass, factor: 0.028349523125, show: "oz" },
    Unit { names: &["st", "stone", "stones"], dim: Dim::Mass, factor: 6.35029318, show: "st" },
    Unit { names: &["ms", "millisecond", "milliseconds"], dim: Dim::Time, factor: 0.001, show: "ms" },
    Unit { names: &["s", "sec", "secs", "second", "seconds"], dim: Dim::Time, factor: 1.0, show: "s" },
    Unit { names: &["min", "mins", "minute", "minutes"], dim: Dim::Time, factor: 60.0, show: "min" },
    Unit { names: &["h", "hr", "hrs", "hour", "hours"], dim: Dim::Time, factor: 3600.0, show: "h" },
    Unit { names: &["d", "day", "days"], dim: Dim::Time, factor: 86400.0, show: "days" },
    Unit { names: &["wk", "week", "weeks"], dim: Dim::Time, factor: 604800.0, show: "weeks" },
    Unit { names: &["yr", "year", "years"], dim: Dim::Time, factor: 31557600.0, show: "years" },
    Unit { names: &["bit", "bits"], dim: Dim::Data, factor: 0.125, show: "bit" },
    Unit { names: &["b", "byte", "bytes"], dim: Dim::Data, factor: 1.0, show: "B" },
    Unit { names: &["kb", "kilobyte", "kilobytes"], dim: Dim::Data, factor: 1e3, show: "kB" },
    Unit { names: &["mb", "megabyte", "megabytes"], dim: Dim::Data, factor: 1e6, show: "MB" },
    Unit { names: &["gb", "gigabyte", "gigabytes"], dim: Dim::Data, factor: 1e9, show: "GB" },
    Unit { names: &["tb", "terabyte", "terabytes"], dim: Dim::Data, factor: 1e12, show: "TB" },
    Unit { names: &["kib", "kibibyte", "kibibytes"], dim: Dim::Data, factor: 1024.0, show: "KiB" },
    Unit { names: &["mib", "mebibyte", "mebibytes"], dim: Dim::Data, factor: 1048576.0, show: "MiB" },
    Unit { names: &["gib", "gibibyte", "gibibytes"], dim: Dim::Data, factor: 1073741824.0, show: "GiB" },
    Unit { names: &["tib", "tebibyte", "tebibytes"], dim: Dim::Data, factor: 1099511627776.0, show: "TiB" },
    Unit { names: &["m/s", "mps"], dim: Dim::Speed, factor: 1.0, show: "m/s" },
    Unit { names: &["km/h", "kmh", "kph"], dim: Dim::Speed, factor: 1.0 / 3.6, show: "km/h" },
    Unit { names: &["mph"], dim: Dim::Speed, factor: 0.44704, show: "mph" },
    Unit { names: &["knot", "knots", "kn"], dim: Dim::Speed, factor: 1852.0 / 3600.0, show: "knots" },
    Unit { names: &["ml", "milliliter", "milliliters", "millilitre", "millilitres"], dim: Dim::Volume, factor: 0.001, show: "ml" },
    Unit { names: &["l", "liter", "liters", "litre", "litres"], dim: Dim::Volume, factor: 1.0, show: "l" },
    Unit { names: &["gal", "gallon", "gallons"], dim: Dim::Volume, factor: 3.785411784, show: "gal" },
    Unit { names: &["cup", "cups"], dim: Dim::Volume, factor: 0.2365882365, show: "cups" },
    Unit { names: &["floz", "fl.oz"], dim: Dim::Volume, factor: 0.0295735295625, show: "fl oz" },
    Unit { names: &["tbsp", "tablespoon", "tablespoons"], dim: Dim::Volume, factor: 0.01478676478125, show: "tbsp" },
    Unit { names: &["tsp", "teaspoon", "teaspoons"], dim: Dim::Volume, factor: 0.00492892159375, show: "tsp" },
    Unit { names: &["j", "joule", "joules"], dim: Dim::Energy, factor: 1.0, show: "J" },
    Unit { names: &["kj", "kilojoule", "kilojoules"], dim: Dim::Energy, factor: 1000.0, show: "kJ" },
    Unit { names: &["cal", "calorie", "calories"], dim: Dim::Energy, factor: 4.184, show: "cal" },
    Unit { names: &["kcal", "kilocalorie", "kilocalories"], dim: Dim::Energy, factor: 4184.0, show: "kcal" },
    Unit { names: &["wh"], dim: Dim::Energy, factor: 3600.0, show: "Wh" },
    Unit { names: &["kwh"], dim: Dim::Energy, factor: 3.6e6, show: "kWh" },
    Unit { names: &["deg", "degree", "degrees", "°"], dim: Dim::Angle, factor: std::f64::consts::PI / 180.0, show: "°" },
    Unit { names: &["rad", "radian", "radians"], dim: Dim::Angle, factor: 1.0, show: "rad" },
    Unit { names: &["c", "°c", "celsius", "degc"], dim: Dim::Temp, factor: 1.0, show: "°C" },
    Unit { names: &["f", "°f", "fahrenheit", "degf"], dim: Dim::Temp, factor: 1.0, show: "°F" },
    Unit { names: &["k", "kelvin"], dim: Dim::Temp, factor: 1.0, show: "K" },
];

fn unit(name: &str) -> Option<&'static Unit> {
    let n = name.to_lowercase();
    UNITS.iter().find(|u| u.names.contains(&n.as_str()))
}

/// Temperatures to and from kelvin.
fn temp_to_k(v: f64, u: &Unit) -> f64 {
    match u.show {
        "°C" => v + 273.15,
        "°F" => (v - 32.0) * 5.0 / 9.0 + 273.15,
        _ => v,
    }
}
fn temp_from_k(v: f64, u: &Unit) -> f64 {
    match u.show {
        "°C" => v - 273.15,
        "°F" => (v - 273.15) * 9.0 / 5.0 + 32.0,
        _ => v,
    }
}

/// A value, in base units, with the unit it was written in.
#[derive(Clone, Copy)]
struct Q {
    v: f64,
    u: Option<&'static Unit>,
}

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Num(f64),
    Word(String),
    Op(char),
}

fn lex(s: &str) -> Option<Vec<Tok>> {
    let c: Vec<char> = s.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < c.len() {
        let ch = c[i];
        if ch.is_whitespace() || ch == '_' {
            i += 1;
        } else if ch.is_ascii_digit() || (ch == '.' && c.get(i + 1).map(|d| d.is_ascii_digit()).unwrap_or(false)) {
            let start = i;
            while i < c.len() && (c[i].is_ascii_digit() || c[i] == '.' || c[i] == ',') {
                i += 1;
            }
            // 1e3, 2.5E-4
            if i < c.len() && (c[i] == 'e' || c[i] == 'E') && c.get(i + 1).map(|d| d.is_ascii_digit() || *d == '-' || *d == '+').unwrap_or(false) {
                let save = i;
                i += 2;
                while i < c.len() && c[i].is_ascii_digit() {
                    i += 1;
                }
                if !c[save + 1..i].iter().any(|d| d.is_ascii_digit()) {
                    i = save;
                }
            }
            let text: String = c[start..i].iter().filter(|d| **d != ',').collect();
            out.push(Tok::Num(text.parse().ok()?));
        } else if ch.is_alphabetic() || ch == '°' {
            let start = i;
            while i < c.len() && (c[i].is_alphanumeric() || c[i] == '°' || c[i] == '/' || c[i] == '.') {
                // "km/h" and "m/s" are one word; "6/2" is not (digits
                // don't start a word).
                if c[i] == '/' && !(i + 1 < c.len() && c[i + 1].is_alphabetic()) {
                    break;
                }
                if c[i] == '.' && !(i + 1 < c.len() && c[i + 1].is_alphabetic()) {
                    break;
                }
                i += 1;
            }
            out.push(Tok::Word(c[start..i].iter().collect()));
        } else if "+-*/^%()×÷x".contains(ch) {
            out.push(Tok::Op(match ch {
                '×' => '*',
                '÷' => '/',
                o => o,
            }));
            i += 1;
        } else if ch == '\'' || ch == '"' {
            out.push(Tok::Word(ch.to_string()));
            i += 1;
        } else {
            return None;
        }
    }
    Some(out)
}

struct P {
    t: Vec<Tok>,
    i: usize,
    /// Something beyond a bare number was used: an operator, a function,
    /// a unit or a constant.
    calc: bool,
}

impl P {
    fn peek(&self) -> Option<&Tok> {
        self.t.get(self.i)
    }
    fn eat_op(&mut self, o: char) -> bool {
        if self.peek() == Some(&Tok::Op(o)) {
            self.i += 1;
            true
        } else {
            false
        }
    }
    fn eat_word(&mut self, w: &str) -> bool {
        if let Some(Tok::Word(x)) = self.peek() {
            if x.eq_ignore_ascii_case(w) {
                self.i += 1;
                return true;
            }
        }
        false
    }

    // sum := term (('+'|'-') term)*
    fn sum(&mut self) -> Option<Q> {
        let mut a = self.term()?;
        loop {
            let sub = if self.eat_op('+') {
                false
            } else if self.eat_op('-') {
                true
            } else {
                return Some(a);
            };
            self.calc = true;
            // "x + 10%": percent of x.
            let save = self.i;
            if let Some(Tok::Num(n)) = self.peek().cloned() {
                self.i += 1;
                if self.eat_op('%') && !matches!(self.peek(), Some(Tok::Num(_)) | Some(Tok::Op('('))) {
                    let d = a.v * n / 100.0;
                    a.v += if sub { -d } else { d };
                    continue;
                }
                self.i = save;
            }
            let b = self.term()?;
            a = add(a, b, sub)?;
        }
    }

    // term := power (('*'|'/'|'%'|implicit) power)*
    fn term(&mut self) -> Option<Q> {
        let mut a = self.power()?;
        loop {
            if self.eat_op('*') || self.eat_word("x") && !self.at_end() {
                self.calc = true;
                let b = self.power()?;
                a = mul(a, b)?;
            } else if self.eat_op('/') {
                self.calc = true;
                let b = self.power()?;
                if b.v == 0.0 {
                    return None;
                }
                a = div(a, b)?;
            } else if self.peek() == Some(&Tok::Op('%')) {
                self.i += 1;
                self.calc = true;
                // "15% of 80"
                if self.eat_word("of") {
                    let b = self.power()?;
                    a = Q { v: a.v / 100.0 * b.v, u: b.u };
                } else if matches!(self.peek(), Some(Tok::Num(_)) | Some(Tok::Op('('))) {
                    let b = self.power()?;
                    if b.v == 0.0 {
                        return None;
                    }
                    a = Q { v: a.v % b.v, u: a.u };
                } else {
                    a = Q { v: a.v / 100.0, u: a.u };
                }
            } else if matches!(self.peek(), Some(Tok::Op('('))) {
                // 2(3+4)
                self.calc = true;
                let b = self.power()?;
                a = mul(a, b)?;
            } else {
                return Some(a);
            }
        }
    }
    fn at_end(&self) -> bool {
        self.i >= self.t.len()
    }

    // power := unary ('^' power)?
    fn power(&mut self) -> Option<Q> {
        let a = self.unary()?;
        if self.eat_op('^') {
            self.calc = true;
            let b = self.power()?;
            if a.u.is_some() || b.u.is_some() {
                return None;
            }
            return Some(Q { v: a.v.powf(b.v), u: None });
        }
        Some(a)
    }

    fn unary(&mut self) -> Option<Q> {
        if self.eat_op('-') {
            let q = self.unary()?;
            return Some(Q { v: -q.v, u: q.u });
        }
        if self.eat_op('+') {
            return self.unary();
        }
        self.atom()
    }

    // atom := number [unit] | constant | func '(' sum ')' | '(' sum ')'
    fn atom(&mut self) -> Option<Q> {
        match self.peek().cloned()? {
            Tok::Num(n) => {
                self.i += 1;
                // A unit written after the number: 5 km, 72f, 3GB.
                if let Some(Tok::Word(w)) = self.peek().cloned() {
                    if let Some(u) = unit(&w) {
                        if !matches!(w.to_lowercase().as_str(), "in" | "to" | "as") || self.unit_follows() || self.i + 1 == self.t.len() {
                            self.i += 1;
                            self.calc = true;
                            let v = if u.dim == Dim::Temp { temp_to_k(n, u) } else { n * u.factor };
                            return Some(Q { v, u: Some(u) });
                        }
                    }
                }
                Some(Q { v: n, u: None })
            }
            Tok::Op('(') => {
                self.i += 1;
                let q = self.sum()?;
                if !self.eat_op(')') && !self.at_end() {
                    return None;
                }
                Some(q)
            }
            Tok::Word(w) => {
                let lw = w.to_lowercase();
                let constant = match lw.as_str() {
                    "pi" | "π" => Some(std::f64::consts::PI),
                    "e" => Some(std::f64::consts::E),
                    "tau" | "τ" => Some(std::f64::consts::TAU),
                    "phi" | "φ" => Some(1.618033988749895),
                    _ => None,
                };
                if let Some(c) = constant {
                    self.i += 1;
                    self.calc = true;
                    return Some(Q { v: c, u: None });
                }
                let f: Option<fn(f64) -> f64> = match lw.as_str() {
                    "sqrt" => Some(f64::sqrt),
                    "cbrt" => Some(f64::cbrt),
                    "abs" => Some(f64::abs),
                    "ln" => Some(f64::ln),
                    "log" | "log10" => Some(f64::log10),
                    "log2" => Some(f64::log2),
                    "exp" => Some(f64::exp),
                    "sin" => Some(f64::sin),
                    "cos" => Some(f64::cos),
                    "tan" => Some(f64::tan),
                    "asin" => Some(f64::asin),
                    "acos" => Some(f64::acos),
                    "atan" => Some(f64::atan),
                    "round" => Some(f64::round),
                    "floor" => Some(f64::floor),
                    "ceil" => Some(f64::ceil),
                    _ => None,
                };
                let f = f?;
                self.i += 1;
                self.calc = true;
                let arg = if self.eat_op('(') {
                    let q = self.sum()?;
                    if !self.eat_op(')') && !self.at_end() {
                        return None;
                    }
                    q
                } else {
                    self.power()?
                };
                // Trigonometry takes degrees when they were written.
                let x = if arg.u.map(|u| u.dim == Dim::Angle).unwrap_or(false) || arg.u.is_none() { arg.v } else { return None };
                let r = f(x);
                if !r.is_finite() {
                    return None;
                }
                Some(Q { v: r, u: None })
            }
            _ => None,
        }
    }
    /// "5 in in cm" — the first "in" is a unit if another "in"/"to" target
    /// follows, or (the target already split off) if it is the last word.
    fn unit_follows(&self) -> bool {
        self.t[self.i + 1..].iter().any(|t| matches!(t, Tok::Word(w) if ["in", "to", "as"].contains(&w.to_lowercase().as_str())))
    }
}

fn add(a: Q, b: Q, sub: bool) -> Option<Q> {
    let s = if sub { -1.0 } else { 1.0 };
    match (a.u, b.u) {
        (None, None) => Some(Q { v: a.v + s * b.v, u: None }),
        (Some(x), Some(y)) if x.dim == y.dim && x.dim != Dim::Temp => Some(Q { v: a.v + s * b.v, u: Some(x) }),
        // 5 km + 300: the bare number in the same unit.
        (Some(x), None) if x.dim != Dim::Temp => Some(Q { v: a.v + s * b.v * x.factor, u: Some(x) }),
        _ => None,
    }
}
fn mul(a: Q, b: Q) -> Option<Q> {
    match (a.u, b.u) {
        (None, None) => Some(Q { v: a.v * b.v, u: None }),
        (Some(x), None) if x.dim != Dim::Temp => Some(Q { v: a.v * b.v, u: Some(x) }),
        (None, Some(y)) if y.dim != Dim::Temp => Some(Q { v: a.v * b.v, u: Some(y) }),
        _ => None,
    }
}
fn div(a: Q, b: Q) -> Option<Q> {
    match (a.u, b.u) {
        (None, None) => Some(Q { v: a.v / b.v, u: None }),
        (Some(x), None) if x.dim != Dim::Temp => Some(Q { v: a.v / b.v, u: Some(x) }),
        // 10 km / 2 km = 5
        (Some(x), Some(y)) if x.dim == y.dim && x.dim != Dim::Temp => Some(Q { v: a.v / b.v, u: None }),
        _ => None,
    }
}

/// Ten significant figures, no trailing zeros, digit groups past four
/// digits; very large or small in scientific form.
fn fmt(v: f64) -> String {
    if v == 0.0 {
        return "0".into();
    }
    let a = v.abs();
    if !(1e-6..1e15).contains(&a) {
        let s = format!("{:.6e}", v);
        let (m, e) = s.split_once('e').unwrap_or((&s, "0"));
        let m = m.trim_end_matches('0').trim_end_matches('.');
        return format!("{m}×10^{}", e.trim_start_matches('+'));
    }
    let decimals = (9 - a.log10().floor() as i32).clamp(0, 12) as usize;
    let s = format!("{:.*}", decimals, v);
    let s = if s.contains('.') { s.trim_end_matches('0').trim_end_matches('.').to_string() } else { s };
    let (int, frac) = s.split_once('.').map(|(i, f)| (i.to_string(), Some(f.to_string()))).unwrap_or((s.clone(), None));
    let (sign, digits) = if let Some(d) = int.strip_prefix('-') { ("-", d.to_string()) } else { ("", int) };
    let grouped = if digits.len() > 4 {
        let mut g = String::new();
        for (k, ch) in digits.chars().enumerate() {
            if k > 0 && (digits.len() - k) % 3 == 0 {
                g.push(',');
            }
            g.push(ch);
        }
        g
    } else {
        digits
    };
    match frac {
        Some(f) => format!("{sign}{grouped}.{f}"),
        None => format!("{sign}{grouped}"),
    }
}

/// The answer to `query`, or None when it is not a calculation.
pub fn eval(query: &str) -> Option<String> {
    let q = query.trim().trim_end_matches('=').trim();
    if q.is_empty() || !q.chars().any(|c| c.is_ascii_digit() || "πτφ".contains(c)) {
        return None;
    }
    let mut toks = lex(q)?;
    // "… in / to / as <unit>" at the end: a conversion.
    let mut target: Option<&'static Unit> = None;
    if toks.len() >= 3 {
        if let (Tok::Word(kw), Tok::Word(u)) = (&toks[toks.len() - 2], &toks[toks.len() - 1]) {
            if ["in", "to", "as", "into"].contains(&kw.to_lowercase().as_str()) {
                if let Some(un) = unit(u) {
                    target = Some(un);
                    toks.truncate(toks.len() - 2);
                }
            }
        }
    }
    let mut p = P { t: toks, i: 0, calc: target.is_some(), };
    let r = p.sum()?;
    if p.i != p.t.len() || !p.calc || !r.v.is_finite() {
        return None;
    }
    match (target, r.u) {
        (Some(t), Some(u)) => {
            if t.dim != u.dim {
                return None;
            }
            let v = if t.dim == Dim::Temp { temp_from_k(r.v, t) } else { r.v / t.factor };
            Some(format!("{} {}", fmt(v), t.show))
        }
        (Some(_), None) => None,
        (None, Some(u)) => {
            let v = if u.dim == Dim::Temp { temp_from_k(r.v, u) } else { r.v / u.factor };
            Some(format!("{} {}", fmt(v), u.show))
        }
        (None, None) => Some(fmt(r.v)),
    }
}

pub fn start() -> Sender<Value> {
    let (tx, rx) = channel::<Value>();
    std::thread::spawn(move || {
        for c in rx {
            let q = c["query"].as_str().unwrap_or("");
            let mut ev = json!({ "ev": "calc", "id": c["id"], "query": q });
            if let Some(r) = eval(q) {
                ev["result"] = json!(r);
            }
            out::emit(ev);
        }
    });
    tx
}

#[cfg(test)]
mod tests {
    use super::eval;
    fn e(q: &str) -> String {
        eval(q).unwrap_or_else(|| "—".into())
    }
    #[test]
    fn sums() {
        assert_eq!(e("12*7.5"), "90");
        assert_eq!(e("2^10/4"), "256");
        assert_eq!(e("(4+5)%4"), "1");
        assert_eq!(e("2(3+4)"), "14");
        assert_eq!(e("1/3"), "0.3333333333");
        assert_eq!(e("sqrt(2)*pi"), "4.442882938");
        assert_eq!(e("15% of 80"), "12");
        assert_eq!(e("80 + 15%"), "92");
        assert_eq!(e("1000000*3"), "3,000,000");
        assert_eq!(e("-3 + 5"), "2");
        assert_eq!(e("2 × 3 ÷ 4"), "1.5");
        assert_eq!(e("1e3 + 1"), "1001");
        assert_eq!(e("sin(90 deg)"), "1");
    }
    #[test]
    fn conversions() {
        assert_eq!(e("5 km in miles"), "3.106855961 mi");
        assert_eq!(e("72f in c"), "22.22222222 °C");
        assert_eq!(e("100 c to f"), "212 °F");
        assert_eq!(e("3 GB in MiB"), "2861.022949 MiB");
        assert_eq!(e("90 min in h"), "1.5 h");
        assert_eq!(e("2 cups in ml"), "473.176473 ml");
        assert_eq!(e("5 km + 300 m"), "5.3 km");
        assert_eq!(e("1.5 kWh in J"), "5,400,000 J");
        assert_eq!(e("60 mph in km/h"), "96.56064 km/h");
        assert_eq!(e("6 ft in cm"), "182.88 cm");
        assert_eq!(e("10 in in cm"), "25.4 cm");
    }
    #[test]
    fn not_sums() {
        for q in ["firefox", "2048", "42", "steam 2", "5 km in kg", "1/0", "", "hello world", "the 3 body problem"] {
            assert_eq!(eval(q), None, "{q}");
        }
    }
}
