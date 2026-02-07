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

#[cfg(test)]
pub mod test {
    use super::*;
    #[test]
    fn test_positive_creation() {
        let v = positive(100);
        assert(v.value == 100, 'value 100');
        assert(v.is_negative == false, 'not negative');
    }

    #[test]
    fn test_negative_creation() {
        let v = negative(100);
        assert(v.value == 100, 'value 100');
        assert(v.is_negative == true, 'is negative');
    }

    #[test]
    fn test_negative_zero_becomes_positive() {
        let v = negative(0);
        assert(v.value == 0, 'value 0');
        assert(v.is_negative == false, 'zero not negative');
    }

    #[test]
    fn test_zero_creation() {
        let v = zero();
        assert(v.value == 0, 'value 0');
        assert(v.is_negative == false, 'not negative');
    }

    #[test]
    fn test_negate_positive() {
        let v = positive(100);
        let neg = negate(v);
        assert(neg.value == 100, 'value stays 100');
        assert(neg.is_negative == true, 'becomes negative');
    }

    #[test]
    fn test_negate_negative() {
        let v = negative(100);
        let pos = negate(v);
        assert(pos.value == 100, 'value stays 100');
        assert(pos.is_negative == false, 'becomes positive');
    }

    #[test]
    fn test_add_signed_same_positive() {
        let a = positive(100);
        let b = positive(50);
        let result = add_signed(a, b);
        assert(result.value == 150, 'sum 150');
        assert(result.is_negative == false, 'positive');
    }

    #[test]
    fn test_add_signed_same_negative() {
        let a = negative(100);
        let b = negative(50);
        let result = add_signed(a, b);
        assert(result.value == 150, 'sum 150');
        assert(result.is_negative == true, 'negative');
    }

    #[test]
    fn test_add_signed_opposite_pos_bigger() {
        let a = positive(100);
        let b = negative(30);
        let result = add_signed(a, b);
        assert(result.value == 70, 'diff 70');
        assert(result.is_negative == false, 'positive');
    }

    #[test]
    fn test_add_signed_opposite_neg_bigger() {
        let a = positive(30);
        let b = negative(100);
        let result = add_signed(a, b);
        assert(result.value == 70, 'diff 70');
        assert(result.is_negative == true, 'negative');
    }

    #[test]
    fn test_add_signed_cancel_out() {
        let a = positive(100);
        let b = negative(100);
        let result = add_signed(a, b);
        assert(result.value == 0, 'zero');
        assert(result.is_negative == false, 'zero positive');
    }

    #[test]
    fn test_safe_sub_a_greater() {
        let result = safe_sub(100, 30);
        assert(result.value == 70, 'diff 70');
        assert(result.is_negative == false, 'positive');
    }

    #[test]
    fn test_safe_sub_b_greater() {
        let result = safe_sub(30, 100);
        assert(result.value == 70, 'diff 70');
        assert(result.is_negative == true, 'negative');
    }

    #[test]
    fn test_apply_pnl_positive() {
        let base: u256 = 1000;
        let pnl = positive(200);
        let result = apply_pnl(base, pnl);
        assert(result == 1200, 'add profit');
    }

    #[test]
    fn test_apply_pnl_negative_partial() {
        let base: u256 = 1000;
        let pnl = negative(200);
        let result = apply_pnl(base, pnl);
        assert(result == 800, 'subtract loss');
    }

    #[test]
    fn test_apply_pnl_negative_exceeds() {
        let base: u256 = 1000;
        let pnl = negative(1500);
        let result = apply_pnl(base, pnl);
        assert(result == 0, 'saturate at 0');
    }
}
