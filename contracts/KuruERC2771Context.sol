//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

abstract contract KuruERC2771Context {
    mapping(address forwarded => bool whiteListed) trustedForwarders;

    function _msgSender() internal view returns (address sender) {
        if (trustedForwarders[msg.sender]) {
            // We've detected that the sender is actually a trusted forwarder,
            // so we read the true sender from the last 20 bytes of the call data.
            // This is the keccak-256 hash of "TRUSTED_FORWARDER" subtracted by 1,
            // and is a solid workaround for the lack of a universal standard to forward sender.
            // This will not be susceptible to replay attacks, and is safe to use.
            // assembly {
            //     sender := shr(96, calldataload(sub(calldatasize(), 20)))
            // }
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            sender = msg.sender;
        }
        return sender;
    }

    function _msgData() internal view returns (bytes calldata) {
        this;
        return msg.data;
    }

    modifier onlyTrustedForwarder() {
        require(trustedForwarders[msg.sender], "KuruERC2771Context: caller is not the trusted forwarder");
        _;
    }
}
