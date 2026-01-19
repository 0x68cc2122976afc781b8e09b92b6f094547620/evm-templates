// SPDX-License-Identifier: Business Source License 1.1
pragma solidity 0.8.18;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {ModuleRegistry} from "../../../../infrastructure/ModuleRegistry.sol";
import {IAccountManager} from "../../../../interfaces/IAccountManager.sol";
import {IAuthorization} from "../../../../interfaces/IAuthorization.sol";
import {ITransferAgent} from "../../../../interfaces/ITransferAgent.sol";
import {IHoldings} from "../../../../interfaces/IHoldings.sol";
import {IAdminTransfer} from "../../../../interfaces/IAdminTransfer.sol";
import {IAdminInstantTransfer} from "../../../../interfaces/IAdminInstantTransfer.sol";
import {ITransferManager} from "../../../../interfaces/ITransferManager.sol";
import {IXChainInstantTransfer} from "../../../../interfaces/IXChainInstantTransfer.sol";

/**
 * @title Implementation of a Money Market Fund
 *
 * This implementation represents a 40 Act Fund in which all operations are cash based.
 * It means all amounts passed to the contract functions with the exception of the contructor's
 * _seed parameter represent the value (in terms of fiat currency) of the fund shares to buy or sell.
 *
 * Purchases or sells of shares requested are settled calling any of the settleTransactions or EndOfDay functions.
 * The price supplied in the settlement functions corresponds to the NAV per share at the moment of the market closing.
 *
 */
contract MoneyMarketFund_V5 is
    Initializable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    IHoldings,
    IAdminTransfer,
    IAdminInstantTransfer,
    ITransferManager,
    IXChainInstantTransfer
{
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant MAX_PAGE_SIZE_BALANCE = 10;
    uint256 public constant NUMBER_SCALE_FACTOR = 1E18;

    bytes32 public constant ROLE_TOKEN_OWNER = keccak256("ROLE_TOKEN_OWNER");
    bytes32 constant AUTHORIZATION_MODULE = keccak256("MODULE_AUTHORIZATION");
    bytes32 constant TRANSACTIONAL_MODULE = keccak256("MODULE_TRANSACTIONAL");

    // ******************** State Variables ******************** //
    // ********************************************************* //

    uint256 public lastKnownPrice;
    ModuleRegistry moduleRegistry;
    // Deprecated Set
    EnumerableSet.AddressSet accountsWithHoldings;

    /// @dev Flag to enable/disable instant shareholder transfers
    bool isInstantTransferOn;
    /// @dev Flag to enable/disable regular ERC-20 shareholder transfers
    bool isERC20TransferOn;
    /// @dev Flag to enable/disable regular ERC-20 3rd party transfers
    bool isERC20ThirdPartyTransferOn;

    // ********************* Modifiers ********************* //
    // ***************************************************** //

    modifier onlyAdminOrWriteAccess() {
        require(
            IAuthorization(
                moduleRegistry.getModuleAddress(AUTHORIZATION_MODULE)
            ).isAdminAccount(_msgSender()) ||
                AccessControlUpgradeable(
                    moduleRegistry.getModuleAddress(AUTHORIZATION_MODULE)
                ).hasRole(keccak256("WRITE_ACCESS_TOKEN"), _msgSender()),
            "NO_WRITE_ACCESS"
        );
        _;
    }

    modifier onlyWhenShareholderExists(address account) {
        require(
            IAuthorization(
                moduleRegistry.getModuleAddress(AUTHORIZATION_MODULE)
            ).isAccountAuthorized(account),
            "SHAREHOLDER_DOES_NOT_EXIST"
        );
        _;
    }

    modifier accountNotFrozen(address account) {
        require(
            !IAccountManager(
                moduleRegistry.getModuleAddress(AUTHORIZATION_MODULE)
            ).isAccountFrozen(account),
            "ACCOUNT_IS_FROZEN"
        );
        _;
    }

    modifier onlyHigherThanZero(uint256 amount) {
        require(amount > 0, "INVALID_AMOUNT");
        _;
    }

    // -------------------- Pagination --------------------  //

    modifier onlyWithValidPageSize(uint256 pageSize, uint256 maxPageSize) {
        require(
            pageSize > 0 && pageSize <= maxPageSize,
            "INVALID_PAGINATION_SIZE"
        );
        _;
    }

    // ********************************************************************* //
    // **********************     MoneyMarketFund     ********************** //
    // ********************************************************************* //

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyRole(ROLE_TOKEN_OWNER) {}

    // ************************* Public Interface ************************* //
    // ******************************************************************** //

    function mintShares(
        address account,
        uint256 shares
    ) external virtual onlyAdminOrWriteAccess {
        _mint(account, shares);
    }

    function burnShares(
        address account,
        uint256 shares
    ) external virtual onlyAdminOrWriteAccess {
        _burn(account, shares);
    }

    /**
     * @notice Enables instant share transfer capability
     *
     * @dev Instant transfer capability allows an admin to transfer
     *      shares between shareholder accounts instantly
     */
    function enableInstantTransfer()
        external
        virtual
        override
        onlyAdminOrWriteAccess
    {
        isInstantTransferOn = true;
        emit InstantTransferStatusUpdated(isInstantTransferOn);
    }

    /**
     * @notice Disables instant share transfer capability
     *
     * @dev Instant transfer capability allows an admin to transfer
     *      shares between shareholder accounts instantly
     */
    function disableInstantTransfer()
        external
        virtual
        override
        onlyAdminOrWriteAccess
    {
        isInstantTransferOn = false;
        emit InstantTransferStatusUpdated(isInstantTransferOn);
    }

    /**
     * @notice Enables ERC-20 share transfer capability
     *
     * @dev ERC-20 transfer capability allows authorized shareholders
     *      to transfer shares between them instantly
     */
    function enableERC20Transfer()
        external
        virtual
        override
        onlyAdminOrWriteAccess
    {
        isERC20TransferOn = true;
        emit ERC20TransferStatusUpdated(isERC20TransferOn);
    }

    /**
     * @notice Disables ERC-20 share transfer capability
     *
     * @dev ERC-20 transfer capability allows authorized shareholders
     *      to transfer shares between them instantly
     */
    function disableERC20Transfer()
        external
        virtual
        override
        onlyAdminOrWriteAccess
    {
        isERC20TransferOn = false;
        emit ERC20TransferStatusUpdated(isERC20TransferOn);
    }

    /**
     * @notice Enables ERC-20 3rd party share transfer capability
     *
     * @dev ERC-20 transferFrom capability allows an authorized spender
     *      account by the shareholder to transfer shares on its behalf,
     *      however shares can only be transfered to other authorized shareholders.
     */
    function enableERC20ThirdPartyTransfer()
        external
        virtual
        override
        onlyAdminOrWriteAccess
    {
        isERC20ThirdPartyTransferOn = true;
        emit ERC20ThirdPartyTransferStatusUpdated(isERC20ThirdPartyTransferOn);
    }

    /**
     * @notice Disables ERC-20 3rd party share transfer capability
     *
     * @dev ERC-20 transferFrom capability allows an authorized spender
     *      account by the shareholder to transfer shares on its behalf,
     *      however shares can only be transfered to other authorized shareholders.
     */
    function disableERC20ThirdPartyTransfer()
        external
        virtual
        override
        onlyAdminOrWriteAccess
    {
        isERC20ThirdPartyTransferOn = false;
        emit ERC20ThirdPartyTransferStatusUpdated(isERC20ThirdPartyTransferOn);
    }

    /**
     * @notice Admin function to transfer shares from one account to another without the need of allowance
     * approval. It uses the internal OpenZeppellin _transfer function for implementing such use cases.
     * To ensure proper access this external API is protected with role based access control.
     * It performs additional validation of input data according to business requirements.
     *
     * @param from source account
     * @param to  destination account to transfer shares
     * @param amount the amount of shares to transfer
     * @param memo the amount of shares to transfer
     */
    function instantTransfer(
        address from,
        address to,
        uint256 amount,
        string memory memo
    )
        external
        virtual
        override
        onlyAdminOrWriteAccess
        onlyWhenShareholderExists(from)
        onlyWhenShareholderExists(to)
        accountNotFrozen(from)
        accountNotFrozen(to)
    {
        require(isInstantTransferOn, "INSTANT_TRANSFER_CAPABILITY_NOT_ENABLED");
        _transfer(from, to, amount);
        emit InstantTransfer(from, to, amount, memo);
    }

    /**
     * @notice See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     * - `to` and sender accounts should be authorized shareholders.
     * - `to` and sender accounts shouldn't have frozen status
     */
    function transfer(
        address to,
        uint256 amount
    )
        public
        virtual
        override
        onlyWhenShareholderExists(_msgSender())
        onlyWhenShareholderExists(to)
        accountNotFrozen(_msgSender())
        accountNotFrozen(to)
        returns (bool)
    {
        require(isInstantTransferOn, "INSTANT_TRANSFER_CAPABILITY_NOT_ENABLED");
        require(isERC20TransferOn, "ERC20_TRANSFER_CAPABILITY_NOT_ENABLED");
        return super.transfer(to, amount);
    }

    /**
     * @notice See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * NOTE: Does not update the allowance if the current allowance
     * is the maximum `uint256`.
     *
     * Requirements:
     *
     * - `from` and `to` cannot be the zero address.
     * - `from` must have a balance of at least `amount`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `amount`.
     * - `from` and `to` accounts should be authorized shareholders.
     * - `from` and `to` sender accounts shouldn't have frozen status
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    )
        public
        virtual
        override
        onlyWhenShareholderExists(from)
        onlyWhenShareholderExists(to)
        accountNotFrozen(from)
        accountNotFrozen(to)
        returns (bool)
    {
        require(isInstantTransferOn, "INSTANT_TRANSFER_CAPABILITY_NOT_ENABLED");
        require(
            isERC20ThirdPartyTransferOn,
            "ERC20_TRANSFER_FROM_CAPABILITY_NOT_ENABLED"
        );
        return super.transferFrom(from, to, amount);
    }

    /**
     * @dev Admin function to transfer shares from one account to another without the need of allowance
     * approval. It uses the internal OpenZeppellin _transfer function for implementing such use cases.
     * To ensure proper access this external API is protected with role based access control.
     *
     * @notice This API is intended only for inter-module interaction.
     * Only modules with the WRITE_ACCESS_TOKEN role are allowed to call this API.
     *
     * @param from source account
     * @param to  destination account to transfer shares
     * @param amount the amount of shares to transfer
     */
    function transferShares(
        address from,
        address to,
        uint256 amount
    ) external virtual override {
        require(
            AccessControlUpgradeable(
                moduleRegistry.getModuleAddress(AUTHORIZATION_MODULE)
            ).hasRole(keccak256("WRITE_ACCESS_TOKEN"), _msgSender()),
            "NO_WRITE_ACCESS"
        );
        _transfer(from, to, amount);
    }

    // DEPRECATED API - accountsWithHoldings not used anymore
    function updateHolderInList(
        address account
    ) external virtual onlyAdminOrWriteAccess {
        if (balanceOf(account) > 0) {
            accountsWithHoldings.add(account);
        } else {
            accountsWithHoldings.remove(account);
        }
    }

    function instantCXTransferIn(
        address account,
        uint256 timestamp,
        uint256 amount,
        string memory memo
    )
        external
        virtual
        override
        onlyAdminOrWriteAccess
        onlyWhenShareholderExists(account)
        onlyHigherThanZero(amount)
        accountNotFrozen(account)
    {
        _mint(account, amount);
        emit InstantCXTransferIn(account, timestamp, amount, memo);
    }

    function instantCXTransferOut(
        address account,
        uint256 amount,
        string memory memo
    )
        external
        virtual
        override
        onlyAdminOrWriteAccess
        onlyWhenShareholderExists(account)
        onlyHigherThanZero(amount)
        accountNotFrozen(account)
    {
        require(
            balanceOf(account) > 0 && balanceOf(account) >= amount,
            "NOT_ENOUGH_BALANCE"
        );
        _burn(account, amount);
        emit InstantCXTransferOut(account, amount, memo);
    }

    // DEPRECATED API - accountsWithHoldings not used anymore
    function removeEmptyHolderFromList(
        address account
    ) external virtual override onlyAdminOrWriteAccess {
        if (balanceOf(account) == 0) {
            accountsWithHoldings.remove(account);
        }
    }

    function updateLastKnownPrice(
        uint256 price
    ) external virtual onlyAdminOrWriteAccess {
        lastKnownPrice = price;
    }

    // -------------------- Utility view functions --------------------  //

    /**
     * @notice Gets the current value of the instant transfer capability status
     *
     */
    function isInstantTransferEnabled()
        external
        view
        virtual
        override
        returns (bool)
    {
        return isInstantTransferOn;
    }

    /**
     * @notice Gets the current value of the ERC-20 transfer capability status
     *
     */
    function isERC20TransferEnabled()
        external
        view
        virtual
        override
        returns (bool)
    {
        return isERC20TransferOn;
    }

    /**
     * @notice Gets the current value of the ERC-20 3rd party transfer capability status
     *
     */
    function isERC20ThirdPartyTransferEnabled()
        external
        view
        virtual
        override
        returns (bool)
    {
        return isERC20ThirdPartyTransferOn;
    }

    function hasEnoughHoldings(
        address account,
        uint256 amount
    ) external view virtual override returns (bool) {
        uint256 holdings = ((balanceOf(account) * lastKnownPrice) /
            NUMBER_SCALE_FACTOR);
        return (holdings > 0 && holdings >= amount);
    }

    function getShareHoldings(
        address account
    ) external view virtual override returns (uint256) {
        return balanceOf(account);
    }

    // **************** Info Query Utilities (External) **************** //

    function getSharesOutstanding() external view virtual returns (uint256) {
        return totalSupply();
    }

    function hasHoldings(address account) external view virtual returns (bool) {
        return balanceOf(account) > 0;
    }

    function getAccountsBalances(
        uint256 pageSize,
        uint256 startIndex
    )
        external
        view
        virtual
        onlyWithValidPageSize(pageSize, MAX_PAGE_SIZE_BALANCE)
        returns (
            bool hasNext,
            uint256 nextIndex,
            address[] memory accounts,
            uint256[] memory balances,
            bool[] memory status
        )
    {
        uint256 count = IAuthorization(
            moduleRegistry.getModuleAddress(AUTHORIZATION_MODULE)
        ).getAuthorizedAccountsCount();
        require(startIndex <= count, "INVALID_PAGINATION_INDEX");

        uint256 arraySize = pageSize;
        hasNext = true;

        uint256 end = startIndex + pageSize;
        if (end >= count) {
            end = count;
            arraySize = end - startIndex;
            hasNext = false;
        }

        accounts = new address[](arraySize);
        balances = new uint256[](arraySize);
        status = new bool[](arraySize);
        nextIndex = end;

        for (uint256 i = startIndex; i < end; ) {
            uint256 resIdx = i - startIndex;
            accounts[resIdx] = IAuthorization(
                moduleRegistry.getModuleAddress(AUTHORIZATION_MODULE)
            ).getAuthorizedAccountAt(i);
            balances[resIdx] = balanceOf(accounts[resIdx]);
            status[resIdx] = IAccountManager(
                moduleRegistry.getModuleAddress(AUTHORIZATION_MODULE)
            ).isAccountFrozen(accounts[resIdx]);
            unchecked {
                i++;
            }
        }
    }

    function getVersion() public pure virtual returns (uint8) {
        return 5;
    }

    // **************** Internal Functions ***************** //
    // ***************************************************** //

    function _isAdminOrPrivilegedModule(
        address account
    ) internal view virtual returns (bool) {
        return
            IAccessControlUpgradeable(
                moduleRegistry.getModuleAddress(AUTHORIZATION_MODULE)
            ).hasRole(keccak256("WRITE_ACCESS_TOKEN"), account) ||
            IAuthorization(
                moduleRegistry.getModuleAddress(AUTHORIZATION_MODULE)
            ).isAdminAccount(account);
    }

    function _isShareholder(
        address account
    ) internal view virtual returns (bool) {
        return
            IAuthorization(
                moduleRegistry.getModuleAddress(AUTHORIZATION_MODULE)
            ).isAccountAuthorized(account);
    }

    function _isMint(
        address from,
        address to
    ) internal view virtual returns (bool) {
        return from == address(0) && to != address(0);
    }

    function _isBurn(
        address from,
        address to
    ) internal view virtual returns (bool) {
        return from != address(0) && to == address(0);
    }

    function _isTransfer(
        address from,
        address to
    ) internal view virtual returns (bool) {
        return from != address(0) && to != address(0);
    }

    // -------------------- ERC20 --------------------  //
    // https://docs.openzeppelin.com/contracts/4.x/api/token/erc20#ERC20-_beforeTokenTransfer-address-address-uint256-
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        super._beforeTokenTransfer(from, to, amount);
        // token transfers must comply with the policy
        // defined by the concrete fund implementation.
        _checkTransferPolicy(from, to);
    }

    // -------------------- Compliance --------------------  //

    function _checkTransferPolicy(address from, address to) internal virtual {
        // ADMIN WORKFLOW
        if (_isAdminOrPrivilegedModule(_msgSender())) {
            if (_isMint(from, to)) {
                // MINT POLICY
                // Only mint tokens to shareholders
                require(
                    _isShareholder(to),
                    "TRANSFER_RESTRICTION_INVALID_ACCOUNT"
                );
            } else if (_isBurn(from, to)) {
                // BURN POLICY
                // NO REQUIREMENT - This scenario shouldn't be possible but
                // we could technically burn shares from non shareholder accounts
            } else if (_isTransfer(from, to)) {
                // TRANSFER POLICY
                // Only transfer between shareholders
                require(
                    _isShareholder(from) && _isShareholder(to),
                    "TRANSFER_RESTRICTION_INVALID_ACCOUNT"
                );
            } else {
                revert("TRANSFER_RESTRICTION_INVALID_ADMIN_OPERATION");
            }
        }
        // SHAREHOLDER WORKFLOW
        else if (_isShareholder(_msgSender())) {
            // Shareholder can only transfer its own shares
            // Destination can only be another shareholder
            require(
                from == _msgSender() && _isShareholder(to),
                "TRANSFER_RESTRICTION_INVALID_ACCOUNT"
            );
        } else {
            // 3rd PARTY WORKFLOW
            // Any 'spender' is only authorized to transfer between authorized shareholders
            require(
                _isShareholder(from) && _isShareholder(to),
                "TRANSFER_RESTRICTION_INVALID_ACCOUNT"
            );
        }
    }
}
