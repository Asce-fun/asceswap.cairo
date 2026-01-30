/// Multiply then divide, round DOWN (when user receives)
/// result = floor((a * b) / c)
pub fn mul_div_down(a: u256, b: u256, c: u256) -> u256 {
    assert(c != 0, 'Division by zero');
    (a * b) / c
}

/// Multiply then divide, round UP (when protocol/user pays)
/// result = ceil((a * b) / c)
pub fn mul_div_up(a: u256, b: u256, c: u256) -> u256 {
    assert(c != 0, 'Division by zero');
    let numerator = a * b;
    let result = numerator / c;
    if numerator % c != 0 {
        result + 1
    } else {
        result
    }
}

/// Division round DOWN
pub fn div_down(a: u256, b: u256) -> u256 {
    assert(b != 0, 'Division by zero');
    a / b
}

/// Division round UP
pub fn div_up(a: u256, b: u256) -> u256 {
    assert(b != 0, 'Division by zero');
    if a == 0 {
        0
    } else if a % b != 0 {
        (a / b) + 1
    } else {
        a / b
    }
}


#[cfg(test)]
pub mod tests {
    use super::*;

    #[test]
    fn test_mul_div_down_basic() {
        // 100 * 50 / 100 = 50
        let result = mul_div_down(100, 50, 100);
        assert(result == 50, 'mul_div_down basic');
    }

    #[test]
    fn test_mul_div_down_rounds_down() {
        // 7 * 3 / 10 = 2 (7*3=21, 21/10=2.1 -> 2)
        let result = mul_div_down(7, 3, 10);
        assert(result == 2, 'should round down');
    }

    #[test]
    fn test_mul_div_up_basic() {
        // 100 * 50 / 100 = 50 (exact division)
        let result = mul_div_up(100, 50, 100);
        assert(result == 50, 'mul_div_up basic');
    }

    #[test]
    fn test_mul_div_up_rounds_up() {
        // 7 * 3 / 10 = 3 (7*3=21, 21/10=2.1 -> 3)
        let result = mul_div_up(7, 3, 10);
        assert(result == 3, 'should round up');
    }

    #[test]
    fn test_mul_div_with_zero_numerator() {
        let result = mul_div_down(0, 100, 50);
        assert(result == 0, 'zero numerator');
    }

    #[test]
    #[should_panic(expected: 'Division by zero')]
    fn test_mul_div_down_div_by_zero() {
        mul_div_down(100, 50, 0);
    }

    #[test]
    #[should_panic(expected: 'Division by zero')]
    fn test_mul_div_up_div_by_zero() {
        mul_div_up(100, 50, 0);
    }

    #[test]
    fn test_div_down_basic() {
        let result = div_down(100, 3);
        assert(result == 33, 'div_down failed');
    }

    #[test]
    fn test_div_up_basic() {
        let result = div_up(100, 3);
        assert(result == 34, 'div_up failed');
    }

    #[test]
    fn test_div_up_exact() {
        let result = div_up(100, 4);
        assert(result == 25, 'exact div');
    }

    #[test]
    fn test_large_numbers() {
        // Test with large numbers typical in DeFi
        let notional: u256 = 1000000000000000000; // 1e18
        let rate: u256 = 500; // 5%
        let bps: u256 = 10000;
        let result = mul_div_down(notional, rate, bps);
        assert(result == 50000000000000000, 'large numbers');
    }
}
