// SPDX-License-Identifier: Business Source License 1.1
pragma solidity 0.8.18;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ModuleRegistry} from "../ModuleRegistry.sol";

abstract contract BaseUpgradeableModule is Initializable, UUPSUpgradeable {
    ModuleRegistry modules;

    function __BaseUpgradeableModule_init() internal onlyInitializing {
        __UUPSUpgradeable_init();
    }

    function __BaseUpgradeableModule_init_unchained()
        internal
        onlyInitializing
    {}

    function getVersion() external pure virtual returns (uint8);
}
