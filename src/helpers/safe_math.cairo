// From zkLend, but can reaudit
// non-audited (just for to know in future that i intend to reaudit)
// not used in audited contracts

use core::num::traits::CheckedMul;

mod errors {
    pub const ADDITION_OVERFLOW: felt252 = 'SM_ADD_OF';
    pub const DIVISION_BY_ZERO: felt252 = 'SM_DIV_ZERO';
    pub const MULTIPLICATION_OVERFLOW: felt252 = 'SM_MUL_OF';
    pub const SUBTRACTION_UNDERFLOW: felt252 = 'SM_SUB_UF';
}

pub fn add(a: felt252, b: felt252) -> felt252 {
    let sum = a + b;
    assert(Into::<_, u256>::into(a) <= Into::<_, u256>::into(sum), errors::ADDITION_OVERFLOW);
    sum
}

pub fn sub(a: felt252, b: felt252) -> felt252 {
    assert(Into::<_, u256>::into(b) <= Into::<_, u256>::into(a), errors::SUBTRACTION_UNDERFLOW);
    a - b
}

pub fn mul(a: felt252, b: felt252) -> felt252 {
    let a: u256 = a.into();
    let b: u256 = b.into();
    let product = a.checked_mul(b).expect(errors::MULTIPLICATION_OVERFLOW);

    product.try_into().expect(errors::MULTIPLICATION_OVERFLOW)
}

pub fn div(a: felt252, b: felt252) -> felt252 {
    assert(b != 0, errors::DIVISION_BY_ZERO);

    let a: u256 = a.into();
    let b: u256 = b.into();
    let quotient = a / b;

    // Safe to unwrap here as `quotient` is always in `felt252` range
    quotient.try_into().unwrap()
}

pub fn div_ceiling(a: felt252, b: felt252) -> felt252 {
    assert(b != 0, errors::DIVISION_BY_ZERO);

    let a: u256 = a.into();
    let b: u256 = b.into();
    let mut quotient = a / b;

    // Need to do this as the corelib's DivRem impls are private
    if b * quotient != a {
        quotient += 1;
    };

    // Safe to unwrap here as `quotient` is always in `felt252` range
    quotient.try_into().unwrap()
}

#[cfg(test)]
mod tests {
    #[test]
    fn test_add_1() {
        assert_eq!(@super::add(1, 2), @3);
    }

    #[test]
    fn test_add_2() {
        assert_eq!(
            @super::add(0x800000000000010ffffffffffffffffffffffffffffffffffffffffffffffff, 1),
            @0x800000000000011000000000000000000000000000000000000000000000000,
        );
    }

    #[test]
    #[should_panic(expected: ('SM_ADD_OF',))]
    fn test_add_overflow_1() {
        super::add(0x800000000000011000000000000000000000000000000000000000000000000, 1);
    }

    #[test]
    #[should_panic(expected: ('SM_ADD_OF',))]
    fn test_add_overflow_2() {
        super::add(
            0x800000000000011000000000000000000000000000000000000000000000000,
            0x800000000000011000000000000000000000000000000000000000000000000,
        );
    }

    #[test]
    fn test_sub_1() {
        assert_eq!(@super::sub(3, 2), @1);
    }

    #[test]
    fn test_sub_2() {
        assert_eq!(
            @super::sub(0x800000000000011000000000000000000000000000000000000000000000000, 1),
            @0x800000000000010ffffffffffffffffffffffffffffffffffffffffffffffff,
        );
    }

    #[test]
    #[should_panic(expected: ('SM_SUB_UF',))]
    fn test_sub_underflow_1() {
        super::sub(0, 1);
    }

    #[test]
    #[should_panic(expected: ('SM_SUB_UF',))]
    fn test_sub_underflow_2() {
        super::sub(
            0x100000000000000000000000000000000,
            0x400000000000000000000000000000000000000000000000000000000000000,
        );
    }

    #[test]
    fn test_mul_1() {
        assert_eq!(@super::mul(2, 3), @6);
    }

    #[test]
    fn test_mul_2() {
        assert_eq!(
            @super::mul(0x100000000000000000000000000000000, 0x400),
            @0x40000000000000000000000000000000000,
        );
    }

    #[test]
    #[should_panic(expected: ('SM_MUL_OF',))]
    fn test_mul_felt_overflow() {
        super::mul(0x400000000000008800000000000000000000000000000000000000000000000, 3);
    }

    #[test]
    #[should_panic(expected: ('SM_MUL_OF',))]
    fn test_mul_uint256_overflow() {
        super::mul(0x400000000000000000000000000000000000000000000000000000000000000, 0x20);
    }

    #[test]
    fn test_div_1() {
        assert_eq!(@super::div(6, 3), @2);
    }

    #[test]
    fn test_div_2() {
        assert_eq!(
            @super::div(0x40000000000000000000000000000000000, 0x400),
            @0x100000000000000000000000000000000,
        );
    }

    #[test]
    fn test_div_3() {
        assert_eq!(@super::div(100, 3), @33);
    }

    #[test]
    #[should_panic(expected: ('SM_DIV_ZERO',))]
    fn test_div_division_by_zero() {
        super::div(999, 0);
    }

    #[test]
    fn test_div_ceiling_1() {
        assert_eq!(@super::div_ceiling(6, 3), @2);
    }

    #[test]
    fn test_div_ceiling_2() {
        assert_eq!(
            @super::div_ceiling(0x40000000000000000000000000000000000, 0x400),
            @0x100000000000000000000000000000000,
        );
    }

    #[test]
    fn test_div_ceiling_3() {
        assert_eq!(@super::div_ceiling(100, 3), @34);
    }

    #[test]
    #[should_panic(expected: ('SM_DIV_ZERO',))]
    fn test_div_ceiling_division_by_zero() {
        super::div_ceiling(999, 0);
    }
}