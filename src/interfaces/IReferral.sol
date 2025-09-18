// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IReferral {
    enum FeeFrom {
        SPOT,
        PERPETUAL
    }

    function handleFee(address user, uint256 feeAmount, FeeFrom feeFrom) external;
}
