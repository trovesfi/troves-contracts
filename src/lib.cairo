pub mod helpers {
    pub mod ERC20Helper;
    pub mod Math;
    pub mod pow;
    pub mod safe_decimal_math;
    pub mod constants;
}

pub mod components {
    pub mod harvester {
        pub mod harvester_lib;
        pub mod defi_spring_ekubo_style;
        pub mod defi_spring_default_style;
        pub mod interface;
        pub mod reward_shares;
    }
    pub mod ekuboSwap;
    pub mod swap;
    pub mod erc4626;
    pub mod common;
    pub mod vesu;
    pub mod accessControl;
}

pub mod interfaces {
    pub mod swapcomp;
    pub mod oracle;
    pub mod common;
    pub mod IERC4626;
    pub mod IVesu;
    pub mod lendcomp;
    pub mod IEkuboCore;
    pub mod IEkuboPosition;
    pub mod IEkuboPositionsNFT;
    pub mod IEkuboDistributor;
    pub mod ERC4626Strategy;
}

pub mod strategies {
    pub mod vesu_rebalance {
        pub mod interface;
        pub mod vesu_rebalance;
        #[cfg(test)]
        pub mod test;
    }
    pub mod cl_vault {
        pub mod interface;
        pub mod cl_vault;
        #[cfg(test)]
        pub mod test;
    }
}

pub mod peripheral {
    pub mod aum_oracle;
}

#[cfg(test)]
pub mod tests {
    pub mod utils;
}

pub mod mocks {
    pub mod defi_spring_snf;
    pub mod defi_spring_ekubo;
}
