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
    } else {
        // Different signs: subtract smaller from larger
        if a.value >= b.value {
            let result = a.value - b.value;
            SignedValue { 
                value: result, 
                is_negative: if result == 0 { false } else { a.is_negative } 
            }
        } else {
            let result = b.value - a.value;
            SignedValue { 
                value: result, 
                is_negative: if result == 0 { false } else { b.is_negative } 
            }
        }
    }
}

/// Subtract two signed values: a - b = a + (-b)
pub fn sub_signed(a: SignedValue, b: SignedValue) -> SignedValue {
    add_signed(a, negate(b))
}

/// Safe subtraction that returns SignedValue (can go negative)
pub fn safe_sub(a: u256, b: u256) -> SignedValue {
    if a >= b {
        positive(a - b)
    } else {
        negative(b - a)
    }
}

/// Convert signed to u256, returning 0 if negative (saturating)
pub fn to_u256_saturating(v: SignedValue) -> u256 {
    if v.is_negative { 0 } else { v.value }
}

/// Add u256 to signed value
pub fn add_u256_to_signed(base: u256, delta: SignedValue) -> SignedValue {
    add_signed(positive(base), delta)
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

/// Check if signed value is below threshold
pub fn is_below_threshold(value: SignedValue, threshold: u256) -> bool {
    if value.is_negative {
        true  // Negative is always below positive threshold
    } else {
        value.value < threshold
    }
}

// /// Trait for operations on SignedValue
// pub trait SignedValueTrait {
//     fn positive(value: u256) -> SignedValue;
//     fn negative(value: u256) -> SignedValue;
//     fn negate(self: SignedValue) -> SignedValue;
//     fn add(self: SignedValue, other: SignedValue) -> SignedValue;
//     fn sub(self: SignedValue, other: SignedValue) -> SignedValue;
//     fn add_u256(self: SignedValue, base: u256) -> SignedValue;
//     fn to_u256_saturating(self: SignedValue) -> u256;
//     fn safe_sub(a: u256, b: u256) -> SignedValue;
//     fn mul_u256(self: SignedValue, b: u256) -> SignedValue;
//     fn div_u256(self: SignedValue, b: u256) -> SignedValue;
//     fn is_below_threshold(self: SignedValue, threshold: u256) -> bool;
// }

// pub impl SignedValueImpl of SignedValueTrait {
//     /// Create positive SignedValue
//     fn positive(value: u256) -> SignedValue {
//         SignedValue { value, is_negative: false }
//     }

//     /// Create negative SignedValue
//     fn negative(value: u256) -> SignedValue {
//         SignedValue { value, is_negative: true }
//     }

//     /// Negate a SignedValue
//     fn negate(self: SignedValue) -> SignedValue {
//         if self.value == 0 {
//             return self;
//         }
//         SignedValue { value: self.value, is_negative: !self.is_negative }
//     }

//     /// Add two SignedValues
//     fn add(self: SignedValue, other: SignedValue) -> SignedValue {
//         if self.is_negative == other.is_negative {
//             SignedValue { value: self.value + other.value, is_negative: self.is_negative }
//         } else if self.value >= other.value {
//             let result = self.value - other.value;
//             SignedValue {
//                 value: result, is_negative: if result == 0 {
//                     false
//                 } else {
//                     self.is_negative
//                 },
//             }
//         } else {
//             let result = other.value - self.value;
//             SignedValue {
//                 value: result, is_negative: if result == 0 {
//                     false
//                 } else {
//                     other.is_negative
//                 },
//             }
//         }
//     }

//     /// Subtract: a - b = a + (-b)
//     fn sub(self: SignedValue, other: SignedValue) -> SignedValue {
//         self.add(other.negate())
//     }

//     /// Add u256 to signed value (for collateral + pnl)
//     fn add_u256(self: SignedValue, base: u256) -> SignedValue {
//         Self::positive(base).add(self)
//     }

//     /// Convert signed to u256, returning 0 if negative (saturating)
//     fn to_u256_saturating(self: SignedValue) -> u256 {
//         if self.is_negative {
//             0
//         } else {
//             self.value
//         }
//     }

//     /// Safe subtraction that returns SignedValue (can go negative)
//     fn safe_sub(a: u256, b: u256) -> SignedValue {
//         if a >= b {
//             Self::positive(a - b)
//         } else {
//             Self::negative(b - a)
//         }
//     }

//     /// Multiply signed by u256
//     fn mul_u256(self: SignedValue, b: u256) -> SignedValue {
//         SignedValue { value: self.value * b, is_negative: self.is_negative }
//     }

//     /// Divide signed by u256
//     fn div_u256(self: SignedValue, b: u256) -> SignedValue {
//         assert(b != 0, 'Division by zero');
//         SignedValue { value: self.value / b, is_negative: self.is_negative }
//     }

//     /// Check if value is below threshold (for liquidation)
//     /// Returns true if value < threshold (accounting for sign)
//     fn is_below_threshold(self: SignedValue, threshold: u256) -> bool {
//         if self.is_negative {
//             true // Negative is always below positive threshold
//         } else {
//             self.value < threshold
//         }
//     }
// }

// //Backward compatibility alias
// pub fn zero() -> SignedValue {
//     SignedValue::default()
// }
// pub fn safe_sub(a: u256, b: u256) -> SignedValue {
//     SignedValueImpl::safe_sub(a, b)
// }

// pub fn safe_add(a: u256, b: u256) -> SignedValue {
//     SignedValueImpl::positive(a).add(SignedValueImpl::positive(b))
// }

// pub fn safe_add_signed(a: SignedValue, b: SignedValue) -> SignedValue {
//     a.add(b)
// }

// pub fn safe_sub_signed(a: SignedValue, b: SignedValue) -> SignedValue {
//     a.sub(b)
// }
// pub fn signed_mul_u256(a: SignedValue, b: u256) -> SignedValue {
//     a.mul_u256(b)
// }
// pub fn signed_div_u256(a: SignedValue, b: u256) -> SignedValue {
//     a.div_u256(b)
// }
