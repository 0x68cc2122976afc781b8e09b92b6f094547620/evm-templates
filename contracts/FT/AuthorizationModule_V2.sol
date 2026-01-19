// SPDX-License-Identifier: Business Source License 1.1
pragma solidity 0.8.18;

import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {BaseUpgradeableModule} from "../../BaseUpgradeableModule.sol";
import {IAccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/IAccessControlUpgradeable.sol";
import {IAccountManager} from "../../../../interfaces/IAccountManager.sol";
import {IAuthorization} from "../../../../interfaces/IAuthorization.sol";
import {ITransactionStorage} from "../../../../interfaces/TransactionIfaces.sol";
import {IHoldings} from "../../../../interfaces/IHoldings.sol";
import {TokenRegistry} from "../../../../infrastructure/TokenRegistry.sol";

import {ModuleRegistry} from "../../../ModuleRegistry.sol";

contract AuthorizationModule_V2 is
    BaseUpgradeableModule,
    AccessControlEnumerableUpgradeable,
    IAuthorization,
    IAccountManager
{
    // Role-based Access Control
    bytes32 public constant MODULE_ID = keccak256("MODULE_AUTHORIZATION");
    bytes32 public constant ROLE_MODULE_OWNER = keccak256("ROLE_MODULE_OWNER");
    bytes32 public constant ROLE_AUTHORIZATION_ADMIN =
        keccak256("ROLE_AUTHORIZATION_ADMIN");
    bytes32 public constant ROLE_FUND_ADMIN = keccak256("ROLE_FUND_ADMIN");
    bytes32 public constant ROLE_FUND_AUTHORIZED =
        keccak256("ROLE_FUND_AUTHORIZED");
    // Inter-module comm
    bytes32 public constant WRITE_ACCESS_TRANSACTION =
        keccak256("WRITE_ACCESS_TRANSACTION");
    bytes32 public constant WRITE_ACCESS_TOKEN =
        keccak256("WRITE_ACCESS_TOKEN");
    bytes32 public constant WRITE_ACCESS_ACC_RECOVERY =
        keccak256("WRITE_ACCESS_ACC_RECOVERY");
    // Account status
    bytes32 public constant ACCESS_CONTROL_FROZEN =
        keccak256("ACCESS_CONTROL_FROZEN");

    address tokenAddress;

    /// @dev This is emitted when an account is authorized
    event AccountAuthorized(address indexed account);
    /// @dev This is emitted when an account is deauthorized
    event AccountDeauthorized(address indexed account);
    /// @dev This is emmited when an account is frozen
    event AccountFrozen(address indexed account, string memo);
    /// @dev This is emmited when an account is unfrozen
    event AccountUnfrozen(address indexed account, string memo);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // Set up the new roles for account status (frozen/unfrozen) and recovery
    function initializeP2PCapability() public reinitializer(2) {
        _setRoleAdmin(ACCESS_CONTROL_FROZEN, ROLE_AUTHORIZATION_ADMIN);
        _setRoleAdmin(WRITE_ACCESS_ACC_RECOVERY, ROLE_AUTHORIZATION_ADMIN);

        _grantRole(
            WRITE_ACCESS_ACC_RECOVERY,
            modules.getModuleAddress(keccak256("MODULE_TRANSFER_AGENT"))
        );
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyRole(ROLE_MODULE_OWNER) {}

    // -------------------- Account Management --------------------  //

    /**
     * @dev Grants the shareholder status to the given account.
     *
     * Only shareholders can have requests defined by the {ITransactionStorage} interface.
     *
     * @param account The address to grant the shareholder status
     *
     */
    function authorizeAccount(
        address account
    ) external virtual override onlyRole(ROLE_AUTHORIZATION_ADMIN) {
        require(account != address(0), "INVALID_ADDRESS");
        require(
            !hasRole(ROLE_FUND_AUTHORIZED, account),
            "SHAREHOLDER_ALREADY_EXISTS"
        );
        _grantRole(ROLE_FUND_AUTHORIZED, account);
        emit AccountAuthorized(account);
    }

    /**
     * @dev Revokes the shareholder status from the given account.
     *
     * Only shareholders can have requests defined by the {ITransactionStorage} interface.
     *
     * @param account The address to revoke the shareholder status from
     *
     */
    function deauthorizeAccount(
        address account
    ) external virtual override onlyRole(ROLE_AUTHORIZATION_ADMIN) {
        require(account != address(0), "INVALID_ADDRESS");
        address txModule = modules.getModuleAddress(
            keccak256("MODULE_TRANSACTIONAL")
        );
        require(txModule != address(0), "MODULE_REQUIRED_NOT_FOUND");
        require(
            hasRole(ROLE_FUND_AUTHORIZED, account),
            "SHAREHOLDER_DOES_NOT_EXISTS"
        );
        require(
            !ITransactionStorage(txModule).hasTransactions(account),
            "PENDING_TRANSACTIONS_EXIST"
        );
        require(
            IHoldings(tokenAddress).getShareHoldings(account) == 0,
            "ACCOUNT_HAS_BALANCE"
        );

        _revokeRole(ROLE_FUND_AUTHORIZED, account);
        emit AccountDeauthorized(account);
    }

    /**
     * @dev Freezes a shareholder's account
     * A frozen account cannot have or create any new trades (pending requests)
     *
     * @param account The address of the shareholder's account
     * @param memo a memo for the frozen operation
     */
    function freezeAccount(
        address account,
        string memory memo
    ) external virtual override onlyRole(ROLE_AUTHORIZATION_ADMIN) {
        address txModule = modules.getModuleAddress(
            keccak256("MODULE_TRANSACTIONAL")
        );
        require(
            hasRole(ROLE_FUND_AUTHORIZED, account),
            "SHAREHOLDER_DOES_NOT_EXISTS"
        );
        require(
            !hasRole(ACCESS_CONTROL_FROZEN, account),
            "ACCOUNT_ALREADY_FROZEN"
        );
        require(
            !ITransactionStorage(txModule).hasTransactions(account),
            "PENDING_TRANSACTIONS_EXIST"
        );

        _grantRole(ACCESS_CONTROL_FROZEN, account);
        emit AccountFrozen(account, memo);
    }

    /**
     * @dev Unfreezes a shareholder's account
     * Unfreezing an account restores its capability to have or create new trades.
     *
     * @param account The address of the shareholder's account
     * @param memo a memo for the unfrozen operation
     */
    function unfreezeAccount(
        address account,
        string memory memo
    ) external virtual override onlyRole(ROLE_AUTHORIZATION_ADMIN) {
        require(
            hasRole(ROLE_FUND_AUTHORIZED, account),
            "SHAREHOLDER_DOES_NOT_EXISTS"
        );
        require(
            hasRole(ACCESS_CONTROL_FROZEN, account),
            "ACCOUNT_IS_NOT_FROZEN"
        );

        _revokeRole(ACCESS_CONTROL_FROZEN, account);
        emit AccountUnfrozen(account, memo);
    }

    /**
     * @dev Unfreezes and deauthorizes an account after an account recovery event
     * This operation is intended to be called by the module with required
     * 'WRITE_ACCESS_ACC_RECOVERY' privileges during the recovery
     *
     * @param from the origin account
     * @param to the destination account
     */
    function removeAccountPostRecovery(
        address from,
        address to
    ) external virtual override onlyRole(WRITE_ACCESS_ACC_RECOVERY) {
        require(
            hasRole(ROLE_FUND_AUTHORIZED, from) &&
                hasRole(ROLE_FUND_AUTHORIZED, to),
            "SHAREHOLDER_DOES_NOT_EXISTS"
        );

        if (hasRole(ACCESS_CONTROL_FROZEN, from)) {
            _revokeRole(ACCESS_CONTROL_FROZEN, from);
            emit AccountUnfrozen(from, "POST_RECOVERY");
        }

        _revokeRole(ROLE_FUND_AUTHORIZED, from);
        emit AccountDeauthorized(from);
    }

    /**
     * @dev Revokes `role` from the calling account.
     *
     * Roles are often managed via {grantRole} and {revokeRole}: this function's
     * purpose is to provide a mechanism for accounts to lose their privileges
     * if they are compromised (such as when a trusted device is misplaced).
     *
     * If the calling account had been revoked `role`, emits a {RoleRevoked}
     * event.
     *
     * Requirements:
     *
     * - the caller must be `account`, the only exception to this rule is
     *   for accounts that have the role 'ROLE_FUND_AUTHORIZED', in such cases
     *   the function caller is required to have the role 'ROLE_AUTHORIZATION_ADMIN'
     *
     * May emit a {RoleRevoked} event.
     *
     */
    function renounceRole(
        bytes32 role,
        address account
    )
        public
        virtual
        override(AccessControlUpgradeable, IAccessControlUpgradeable)
    {
        if (role == ROLE_FUND_AUTHORIZED || role == ACCESS_CONTROL_FROZEN) {
            require(
                hasRole(ROLE_FUND_AUTHORIZED, account),
                "ACCOUNT_IS_NOT_A_SHAREHOLDER"
            );
            require(
                hasRole(ROLE_AUTHORIZATION_ADMIN, _msgSender()),
                "CALLER_IS_NOT_AN_ADMIN"
            );
        } else {
            require(
                account == _msgSender(),
                "AccessControl: can only renounce roles for self"
            );
        }

        _revokeRole(role, account);
    }

    // --------------------------- Views ---------------------------  //

    function isAccountAuthorized(
        address account
    ) external view virtual override returns (bool) {
        return hasRole(ROLE_FUND_AUTHORIZED, account);
    }

    function isAdminAccount(
        address account
    ) external view virtual override returns (bool) {
        return hasRole(ROLE_FUND_ADMIN, account);
    }

    function isAccountFrozen(
        address account
    ) external view virtual override returns (bool) {
        return hasRole(ACCESS_CONTROL_FROZEN, account);
    }

    function getAuthorizedAccountsCount()
        external
        view
        virtual
        override
        returns (uint256)
    {
        return getRoleMemberCount(ROLE_FUND_AUTHORIZED);
    }

    function getAuthorizedAccountAt(
        uint256 index
    ) external view virtual override returns (address) {
        return getRoleMember(ROLE_FUND_AUTHORIZED, index);
    }

    function getVersion() public pure virtual override returns (uint8) {
        return 2;
    }
}
