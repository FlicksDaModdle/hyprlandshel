//! A damped spring, as common/Spring.qml has it: `response` is the period
//! in ms, `bounce` how far it overshoots (scaled by Settings' motion
//! bounce; none in the "smooth" motion style), stepped once a frame. The
//! same numbers give the same motion as the Quickshell shell.

#[derive(Clone, Copy)]
pub struct Motion {
    /// Settings → Motion: "springy" or "smooth".
    pub springy: bool,
    /// 0–200 %.
    pub bounce: f64,
    /// 0–250 %; 0 is no animation at all.
    pub speed: f64,
}

#[derive(Clone)]
pub struct Spring {
    pub value: f64,
    velocity: f64,
    to: f64,
    response: f64,
    bounce: f64,
    span: f64,
    fresh: bool,
    pub moving: bool,
}

impl Spring {
    pub fn new(v: f64) -> Spring {
        Spring { value: v, velocity: 0.0, to: v, response: 380.0, bounce: 1.0, span: 1.0, fresh: false, moving: false }
    }

    pub fn snap(&mut self, v: f64) {
        self.value = v;
        self.to = v;
        self.velocity = 0.0;
        self.moving = false;
    }

    /// Heads for `to`, from wherever it is and however fast it is going.
    pub fn go(&mut self, to: f64, response: f64, bounce: f64, m: &Motion) {
        self.to = to;
        self.response = response;
        self.bounce = bounce;
        if m.speed <= 0.0 {
            self.snap(to);
            return;
        }
        let w = self.omega();
        self.span = (to - self.value).abs().max(self.velocity.abs() / w);
        self.fresh = true;
        self.moving = true;
    }

    /// Flung from where it is at `velocity` (per second), back to rest at
    /// `to`: a shake.
    pub fn kick(&mut self, velocity: f64, to: f64, response: f64, bounce: f64, m: &Motion) {
        if m.speed <= 0.0 {
            return;
        }
        self.to = to;
        self.response = response;
        self.bounce = bounce;
        self.velocity = velocity;
        let w = self.omega();
        self.span = (to - self.value).abs().max(velocity.abs() / w);
        self.fresh = true;
        self.moving = true;
    }

    fn omega(&self) -> f64 {
        2.0 * std::f64::consts::PI / (self.response / 1000.0).max(0.02)
    }

    /// `dt` in seconds since the last frame.
    pub fn step(&mut self, dt: f64, m: &Motion) {
        if !self.moving {
            return;
        }
        // The first frame after waking counts as one frame, however long
        // the loop slept; after that a long frame is cut to 1/15 s, so a
        // stall doesn't fling it.
        let dt = dt.min(if self.fresh { 1.0 / 60.0 } else { 1.0 / 15.0 }) * m.speed / 100.0;
        self.fresh = false;
        if dt <= 0.0 {
            return;
        }
        let amount = if m.springy { self.bounce.max(0.0) * m.bounce / 100.0 } else { 0.0 };
        let z = (1.0 - 0.2 * amount).max(0.5);
        let w = self.omega();
        let (x, v) = (self.value - self.to, self.velocity);
        let (nx, nv) = if z > 0.999 {
            let e = (-w * dt).exp();
            let b = v + w * x;
            ((x + b * dt) * e, (b - w * (x + b * dt)) * e)
        } else {
            let wd = w * (1.0 - z * z).sqrt();
            let e = (-z * w * dt).exp();
            let (c, s) = ((wd * dt).cos(), (wd * dt).sin());
            let b = (v + z * w * x) / wd;
            (e * (x * c + b * s), e * ((wd * b - z * w * x) * c - (z * w * b + wd * x) * s))
        };
        let eps = (self.span * 5e-4).max(1e-4);
        if nx.abs() < eps && nv.abs() < eps * w {
            self.snap(self.to);
            return;
        }
        self.velocity = nv;
        self.value = self.to + nx;
    }
}
