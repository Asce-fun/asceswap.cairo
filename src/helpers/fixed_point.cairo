/// result = floor((a * b) / c)
pub fn mul_div_down(a: u256, b: u256, c: u256) -> u256 {
    assert(c != 0, 'Division by zero');
    (a * b) / c
}

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

/// Division rounding DOWN
pub fn div_down(a: u256, b: u256) -> u256 {
    assert(b != 0, 'Division by zero');
    a / b
}

/// Division rounding UP
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
