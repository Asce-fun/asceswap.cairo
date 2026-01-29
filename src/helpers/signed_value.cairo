use crate::types::asce_swap::SignedValue;


/// Create a positive SignedValue
#[inline(always)]
pub fn positive(value: u256) -> SignedValue {
    SignedValue { value, is_negative: false }
}

/// Create a negative SignedValue
#[inline(always)]
pub fn negative(value: u256) -> SignedValue {
    if value == 0 {
        SignedValue { value: 0, is_negative: false }
    } else {
        SignedValue { value, is_negative: true }
    }
}

/// Create zero
#[inline(always)]
pub fn zero() -> SignedValue {
    SignedValue { value: 0, is_negative: false }
}

/// Negate a signed value
pub fn negate(v: SignedValue) -> SignedValue {
    if v.value == 0 {
        return zero();
    }
    SignedValue { value: v.value, is_negative: !v.is_negative }
}

/// Add two signed values
pub fn add_signed(a: SignedValue, b: SignedValue) -> SignedValue {
    if a.is_negative == b.is_negative {
        // Same sign: add magnitudes, keep sign
        SignedValue { value: a.value + b.value, is_negative: a.is_negative }
    } else if a.value >= b.value {
        let result = a.value - b.value;
        SignedValue { value: result, is_negative: if result == 0 {
            false
        } else {
            a.is_negative
        } }
    } else {
        let result = b.value - a.value;
        SignedValue { value: result, is_negative: if result == 0 {
            false
        } else {
            b.is_negative
        } }
    }
}


/// Safe subtraction returning signed result: a - b
pub fn safe_sub(a: u256, b: u256) -> SignedValue {
    if a >= b {
        positive(a - b)
    } else {
        negative(b - a)
    }
}

/// Apply signed PnL to unsigned base (saturates at 0)
pub fn apply_pnl(base: u256, pnl: SignedValue) -> u256 {
    if pnl.is_negative {
        if pnl.value >= base {
            0
        } else {
            base - pnl.value
        }
    } else {
        base + pnl.value
    }
}
