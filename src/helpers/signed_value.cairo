use crate::types::asce_swap::SignedValue;

/// Trait for operations on SignedValue
pub trait SignedValueTrait {
    fn positive(value: u256) -> SignedValue;
    fn negative(value: u256) -> SignedValue;
    fn negate(self: SignedValue) -> SignedValue;
    fn add(self: SignedValue, other: SignedValue) -> SignedValue;
    fn sub(self: SignedValue, other: SignedValue) -> SignedValue;
    fn add_u256(self: SignedValue, base: u256) -> SignedValue;
    fn to_u256_saturating(self: SignedValue) -> u256;
    fn safe_sub(a: u256, b: u256) -> SignedValue;
    fn mul_u256(self: SignedValue, b: u256) -> SignedValue;
    fn div_u256(self: SignedValue, b: u256) -> SignedValue;
    fn is_below_threshold(self: SignedValue, threshold: u256) -> bool;
}

impl SignedValueImpl of SignedValueTrait {
    /// Create positive SignedValue
    fn positive(value: u256) -> SignedValue {
        SignedValue { value, is_negative: false }
    }

    /// Create negative SignedValue
    fn negative(value: u256) -> SignedValue {
        SignedValue { value, is_negative: true }
    }

    /// Negate a SignedValue
    fn negate(self: SignedValue) -> SignedValue {
        if self.value == 0 {
            return self;
        }
        SignedValue { value: self.value, is_negative: !self.is_negative }
    }

    /// Add two SignedValues
    fn add(self: SignedValue, other: SignedValue) -> SignedValue {
        if self.is_negative == other.is_negative {
            SignedValue { value: self.value + other.value, is_negative: self.is_negative }
        } else if self.value >= other.value {
            let result = self.value - other.value;
            SignedValue {
                value: result, is_negative: if result == 0 {
                    false
                } else {
                    self.is_negative
                },
            }
        } else {
            let result = other.value - self.value;
            SignedValue {
                value: result, is_negative: if result == 0 {
                    false
                } else {
                    other.is_negative
                },
            }
        }
    }

    /// Subtract: a - b = a + (-b)
    fn sub(self: SignedValue, other: SignedValue) -> SignedValue {
        self.add(other.negate())
    }

    /// Add u256 to signed value (for collateral + pnl)
    fn add_u256(self: SignedValue, base: u256) -> SignedValue {
        Self::positive(base).add(self)
    }

    /// Convert signed to u256, returning 0 if negative (saturating)
    fn to_u256_saturating(self: SignedValue) -> u256 {
        if self.is_negative {
            0
        } else {
            self.value
        }
    }

    /// Safe subtraction that returns SignedValue (can go negative)
    fn safe_sub(a: u256, b: u256) -> SignedValue {
        if a >= b {
            Self::positive(a - b)
        } else {
            Self::negative(b - a)
        }
    }

    /// Multiply signed by u256
    fn mul_u256(self: SignedValue, b: u256) -> SignedValue {
        SignedValue { value: self.value * b, is_negative: self.is_negative }
    }

    /// Divide signed by u256
    fn div_u256(self: SignedValue, b: u256) -> SignedValue {
        assert(b != 0, 'Division by zero');
        SignedValue { value: self.value / b, is_negative: self.is_negative }
    }

    /// Check if value is below threshold (for liquidation)
    /// Returns true if value < threshold (accounting for sign)
    fn is_below_threshold(self: SignedValue, threshold: u256) -> bool {
        if self.is_negative {
            true // Negative is always below positive threshold
        } else {
            self.value < threshold
        }
    }
}
