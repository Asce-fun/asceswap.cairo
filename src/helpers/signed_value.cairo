use crate::types::asce_swap::SignedValue;


///create positive SignedValue
pub fn positive(value: u256) -> SignedValue {
    SignedValue { value, is_negative: false }
}
///create negative SignedValue
pub fn negative(value: u256) -> SignedValue {
    SignedValue { value, is_negative: true }
}

/// Negate a SignedValue
pub fn negate(v: SignedValue) -> SignedValue {
    if v.value == 0 {
        return v;
    }
    SignedValue { value: v.value, is_negative: !v.is_negative }
}


///Add two SignedValues
pub fn add_signed(a: SignedValue, b: SignedValue) -> SignedValue {
    if a.is_negative == b.is_negative {
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


/// Subtract: a - b = a + (-b)
pub fn sub_signed(a: SignedValue, b: SignedValue) -> SignedValue {
    add_signed(a, negate(b))
}

/// Add u256 to signed value (for collateral + pnl)
pub fn add_u256_to_signed(base: u256, delta: SignedValue) -> SignedValue {
    add_signed(positive(base), delta)
}

/// Convert signed to u256, returning 0 if negative (saturating)
pub fn to_u256_saturating(v: SignedValue) -> u256 {
    if v.is_negative {
        0
    } else {
        v.value
    }
}

/// Safe subtraction that returns SignedValue (can go negative)
pub fn safe_sub(a: u256, b: u256) -> SignedValue {
    if a >= b {
        positive(a - b)
    } else {
        negative(b - a)
    }
}


/// Multiply signed by u256
pub fn mul_signed_u256(a: SignedValue, b: u256) -> SignedValue {
    SignedValue { value: a.value * b, is_negative: a.is_negative }
}

/// Divide signed by u256
pub fn div_signed_u256(a: SignedValue, b: u256) -> SignedValue {
    assert(b != 0, 'Division by zero');
    SignedValue { value: a.value / b, is_negative: a.is_negative }
}

/// Check if value is below threshold (for liquidation)
/// Returns true if value < threshold (accounting for sign)
pub fn is_below_threshold(value: SignedValue, threshold: u256) -> bool {
    if value.is_negative {
        true // Negative is always below positive threshold
    } else {
        value.value < threshold
    }
}
