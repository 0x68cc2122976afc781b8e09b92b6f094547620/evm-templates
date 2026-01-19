// SPDX-License-Identifier: Business Source License 1.1
pragma solidity 0.8.18;

import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {EnumerableSetUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import {BaseUpgradeableModule} from "../../BaseUpgradeableModule.sol";

import {IAuthorization} from "../../../../interfaces/IAuthorization.sol";
import {IAdminTransfer} from "../../../../interfaces/IAdminTransfer.sol";
import {ITransactionStorage} from "../../../../interfaces/TransactionIfaces.sol";
import {IExtendedTransactionDetail} from "../../../../interfaces/TransactionIfaces.sol";
import {ITransferAgentExt} from "../../../../interfaces/ITransferAgentExt.sol";
import {ITransferAgentXChain} from "../../../../interfaces/ITransferAgentXChain.sol";
import {IRecovery} from "../../../../interfaces/IRecovery.sol";
import {IAccountManager} from "../../../../interfaces/IAccountManager.sol";
import {MoneyMarketFund} from "../../../../MoneyMarketFund.sol";
import {ModuleRegistry} from "../../../ModuleRegistry.sol";
import {TokenRegistry} from "../../../../infrastructure/TokenRegistry.sol";

contract TransferAgentModule_V5 is
    BaseUpgradeableModule,
    AccessControlEnumerableUpgradeable,
    ITransferAgentExt,
    IRecovery,
    ITransferAgentXChain
{
    bytes32 public constant MODULE_ID = keccak256("MODULE_TRANSFER_AGENT");
    bytes32 public constant ROLE_MODULE_OWNER = keccak256("ROLE_MODULE_OWNER");
    bytes32 constant AUTHORIZATION_MODULE = keccak256("MODULE_AUTHORIZATION");
    bytes32 constant TRANSACTIONAL_MODULE = keccak256("MODULE_TRANSACTIONAL");

    uint256 public constant MAX_ACCOUNT_PAGE_SIZE = 50;
    uint256 public constant MAX_TX_PAGE_SIZE = 50;
    uint256 public constant MAX_CX_TX_PAGE_SIZE = 10;

    TokenRegistry tokenRegistry;
    MoneyMarketFund moneyMarketFund;
    /// @dev The Id of the token associated with the settlement and div distribution of this contract
    /// At the moment only a default token Id can be provided during contract initialization
    /// but in the future more tokens could be used using the token registry
    string tokenId;

    // *********************** Events *********************** //
    // ****************************************************** //

    /**
     * @dev This is emitted when dividends are paid to the shareholder,
     * in the very unlikely scenario of rate being lower than 0 the dividend
     * will be deducted from the shareholder's balance instead:
     */
    event DividendDistributed(
        address indexed account,
        uint256 indexed date,
        int256 rate,
        uint256 price,
        uint256 shares,
        uint256 dividendCashAmount,
        uint256 dividendBasis,
        bool isNegativeYield
    );
    /// @dev This is emitted when a shareholder request is settled:
    event TransactionSettled(
        address indexed account,
        uint256 indexed date,
        uint8 indexed transactionType,
        bytes32 transactionId,
        uint256 price,
        uint256 amount,
        uint256 shares
    );
    /// @dev This is emitted when a share transfer is settled:
    event TransferSettled(
        address indexed from,
        address indexed to,
        uint256 indexed date,
        uint8 transactionType,
        bytes32 transactionId,
        uint256 price,
        uint256 shares
    );
    /// @dev This is emitted when a manual adjustment of the balance is performed by the TA:
    event BalanceAdjusted(address indexed account, uint256 amount, string memo);
    /// @dev This is emmited when the entire balance of an account is recovered by the TA:
    event AccountRecovered(
        address indexed fromAccount,
        address indexed toAccount,
        uint256 amount,
        string memo
    );
    /// @dev This is emmited when a partial balance amount of an account is recovered by the TA:
    event AssetRecovered(
        address indexed fromAccount,
        address indexed toAccount,
        uint256 amount,
        string memo
    );

    // ---------------------- Modifiers ----------------------  //

    modifier onlyAdmin() {
        require(
            IAuthorization(modules.getModuleAddress(AUTHORIZATION_MODULE))
                .isAdminAccount(msg.sender),
            "CALLER_IS_NOT_AN_ADMIN"
        );
        _;
    }

    modifier onlyWhenShareholderExists(address account) {
        require(
            IAuthorization(modules.getModuleAddress(AUTHORIZATION_MODULE))
                .isAccountAuthorized(account),
            "SHAREHOLDER_DOES_NOT_EXIST"
        );
        _;
    }

    modifier onlyWithValidRate(int256 rate) {
        require(rate != 0, "INVALID_DIV_RATE");
        _;
    }

    modifier onlyValidPaginationSize(
        uint256 arrayLength,
        uint256 maxArraySize
    ) {
        require(arrayLength <= maxArraySize, "INVALID_PAGINATION_SIZE");
        _;
    }

    modifier whenTransactionsExist(address account) {
        if (
            ITransactionStorage(modules.getModuleAddress(TRANSACTIONAL_MODULE))
                .hasTransactions(account)
        ) {
            _;
        }
    }

    modifier whenNotInArray(bytes32[] calldata txIds, bytes32 currentTxId) {
        if (txIds.length == 0) {
            _;
            return;
        }

        bool found = false;
        uint256 arrayLength = txIds.length;
        for (uint256 i = 0; i < arrayLength; ) {
            if (txIds[i] == currentTxId) {
                found = true;
                break;
            }
            unchecked {
                i++;
            }
        }
        if (!found) _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyRole(ROLE_MODULE_OWNER) {}

    function getVersion() external pure virtual override returns (uint8) {
        return 5;
    }

    // ---------------- TA operations ----------------  //

    /**
     * @notice Distributes dividends to the account if it has holdings.
     *
     * The amount of shares to distribute in the form of divideds are calculated as follows:
     *
     *      Share dividends = (account's balance * rate) / price
     *
     * This operation will mint or burn shares according to the rate provided.
     *      If rate > 0 it will mint shares
     *      If rate < 0 it will burn shares
     *
     * @param accounts The address of the shareholders' accounts
     * @param date The date of the request as a UNIX timestamp
     * @param rate The rate for the given shareholder
     * @param price The NAV price per share
     *
     */
    function distributeDividends(
        address[] memory accounts,
        uint256 date,
        int256 rate,
        uint256 price
    )
        external
        virtual
        override
        onlyAdmin
        onlyWithValidRate(rate)
        onlyValidPaginationSize(accounts.length, MAX_ACCOUNT_PAGE_SIZE)
    {
        moneyMarketFund.updateLastKnownPrice(price);
        for (uint i = 0; i < accounts.length; ) {
            _processDividends(
                accounts[i],
                moneyMarketFund.balanceOf(accounts[i]),
                date,
                rate,
                price
            );
            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice Distributes dividends and settles existing requests prior to the specified date for the given account.
     *
     * @param accounts The address of the shareholders' accounts
     * @param date The date of the request as a UNIX timestamp
     * @param rate The rate
     * @param price The NAV price per share
     *
     */
    function endOfDay(
        address[] calldata accounts,
        bytes32[] calldata txIds,
        uint256 date,
        int256 rate,
        uint256 price
    )
        external
        virtual
        override
        onlyAdmin
        onlyWithValidRate(rate)
        onlyValidPaginationSize(accounts.length, MAX_ACCOUNT_PAGE_SIZE)
        onlyValidPaginationSize(txIds.length, MAX_TX_PAGE_SIZE)
    {
        moneyMarketFund.updateLastKnownPrice(price);
        for (uint i = 0; i < accounts.length; ) {
            _processDividends(
                accounts[i],
                moneyMarketFund.balanceOf(accounts[i]),
                date,
                rate,
                price
            );
            _processSettlements(txIds, accounts[i], date, price);
            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice Settles existing requests prior to the specified date for the given account.
     *
     * This operation will mint or burn shares according to the request type.
     *
     * @param accounts The address of the shareholders' accounts
     * @param date The date of the request as a UNIX timestamp
     * @param price The NAV price per share
     *
     */
    function settleTransactions(
        address[] calldata accounts,
        bytes32[] calldata txIds,
        uint256 date,
        uint256 price
    )
        external
        virtual
        override
        onlyAdmin
        onlyValidPaginationSize(accounts.length, MAX_ACCOUNT_PAGE_SIZE)
        onlyValidPaginationSize(txIds.length, MAX_TX_PAGE_SIZE)
    {
        moneyMarketFund.updateLastKnownPrice(price);
        for (uint i = 0; i < accounts.length; ) {
            _processSettlements(txIds, accounts[i], date, price);
            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice Distributes full or proportional dividends to the account if it has holdings.
     *
     * The amount of shares to distribute in the form of divideds are calculated as follows:
     *
     *      If the adjusted shares for the account are greather than zero,
     *          Share dividends = (adjusted shares * rate) / price
     *      Otherwise,
     *          Share dividends = (account's balance * rate) / price
     *
     * This operation will mint or burn shares according to the rate provided.
     *      If rate > 0 it will mint shares
     *      If rate < 0 it will burn shares
     *
     * @param accounts The address of the shareholders' accounts
     * @param adjustedShares The holdings to calculate the proportional yield if any
     * @param date The date of the request as a UNIX timestamp
     * @param rate The rate for the given shareholder
     * @param price The NAV price per share
     *
     */
    function distributeDividends(
        address[] calldata accounts,
        uint256[] calldata adjustedShares,
        uint256 date,
        int256 rate,
        uint256 price
    )
        external
        virtual
        override
        onlyAdmin
        onlyWithValidRate(rate)
        onlyValidPaginationSize(accounts.length, MAX_ACCOUNT_PAGE_SIZE)
        onlyValidPaginationSize(adjustedShares.length, MAX_ACCOUNT_PAGE_SIZE)
    {
        require(
            accounts.length == adjustedShares.length,
            "ARRAY_LENGTH_MISMATCH"
        );
        moneyMarketFund.updateLastKnownPrice(price);
        for (uint i = 0; i < accounts.length; ) {
            uint256 accountBalance;
            if (adjustedShares[i] == 0) {
                accountBalance = moneyMarketFund.balanceOf(accounts[i]);
            } else {
                accountBalance = adjustedShares[i];
            }
            _processDividends(accounts[i], accountBalance, date, rate, price);
            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice Distributes full or partial dividends and settles existing requests
     *         prior to the specified date for the given account.
     *
     * @param accounts The address of the shareholders' accounts
     * @param adjustedShares The holdings to calculate the proportional yield if any
     * @param date The date of the request as a UNIX timestamp
     * @param rate The rate
     * @param price The NAV price per share
     *
     */
    function endOfDay(
        address[] calldata accounts,
        uint256[] calldata adjustedShares,
        bytes32[] calldata txIds,
        uint256 date,
        int256 rate,
        uint256 price
    )
        external
        virtual
        override
        onlyAdmin
        onlyWithValidRate(rate)
        onlyValidPaginationSize(accounts.length, MAX_ACCOUNT_PAGE_SIZE)
        onlyValidPaginationSize(adjustedShares.length, MAX_ACCOUNT_PAGE_SIZE)
        onlyValidPaginationSize(txIds.length, MAX_TX_PAGE_SIZE)
    {
        require(
            accounts.length == adjustedShares.length,
            "ARRAY_LENGTH_MISMATCH"
        );
        moneyMarketFund.updateLastKnownPrice(price);
        for (uint i = 0; i < accounts.length; ) {
            uint256 accountBalance;
            if (adjustedShares[i] == 0) {
                accountBalance = moneyMarketFund.balanceOf(accounts[i]);
            } else {
                accountBalance = adjustedShares[i];
            }
            _processDividends(accounts[i], accountBalance, date, rate, price);
            _processSettlements(txIds, accounts[i], date, price);
            unchecked {
                i++;
            }
        }
    }

    // ---------------- TA Cross-chain operations ----------------  //

    /**
     * @notice Settles all the account's request given as an array of id's prior to the specified date.
     *
     * @param account the address of the shareholders' account
     * @param requestIds an array with the id's of the requests to process
     * @param date the maximum date to finish processing request from represented as a UNIX timestamp
     * @param price the NAV price per share
     */
    function settleCXTransactions(
        address account,
        bytes32[] memory requestIds,
        uint256 date,
        uint256 price
    )
        external
        virtual
        override
        onlyAdmin
        onlyWhenShareholderExists(account)
        onlyValidPaginationSize(requestIds.length, MAX_CX_TX_PAGE_SIZE)
    {
        for (uint i = 0; i < requestIds.length; ) {
            _processCXSettlement(account, requestIds[i], date, price);
            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice Settles the given cross-chain request prior to the specified date for the given account.
     *
     * This operation will mint or burn shares according to the request type.
     *
     * @param account the address of the shareholders' account
     * @param requestId the id of the request to process
     * @param date the maximum date to process the request represented as a UNIX timestamp
     * @param price The NAV price per share
     */
    function settleCXTransaction(
        address account,
        bytes32 requestId,
        uint256 date,
        uint256 price
    ) external virtual override onlyAdmin onlyWhenShareholderExists(account) {
        moneyMarketFund.updateLastKnownPrice(price);
        _processCXSettlement(account, requestId, date, price);
    }

    // ---------------- TA Admin operations ----------------  //

    /**
     * @notice Updates the current balance of a shareholder's account to a new one.
     *
     * @param account the address of the shareholders' account
     * @param currentBalance the current account's balance
     * @param newBalance the new balance for the account
     * @param memo a memo for the balance adjustment operation
     */
    function adjustBalance(
        address account,
        uint256 currentBalance,
        uint256 newBalance,
        string memory memo
    ) external virtual override onlyAdmin onlyWhenShareholderExists(account) {
        require(
            currentBalance == moneyMarketFund.balanceOf(account),
            "CURRENT_BALANCE_MISMATCH"
        );
        require(
            newBalance != moneyMarketFund.balanceOf(account),
            "NO_ADJUSTMENT_REQUIRED"
        );

        if (currentBalance > newBalance) {
            moneyMarketFund.burnShares(account, (currentBalance - newBalance));
            emit BalanceAdjusted(account, (currentBalance - newBalance), memo);
        } else {
            moneyMarketFund.mintShares(account, (newBalance - currentBalance));
            emit BalanceAdjusted(account, (newBalance - currentBalance), memo);
        }
    }

    /**
     * @dev Recovers the entire balance of an account
     *
     * @param from the account holding the balance to recover
     * @param to the destination account to transfer the balance
     * @param memo a memo for the recovery operation
     */
    function recoverAccount(
        address from,
        address to,
        string memory memo
    ) external virtual override onlyAdmin {
        // Checks
        require(
            !ITransactionStorage(modules.getModuleAddress(TRANSACTIONAL_MODULE))
                .hasTransactions(from),
            "PENDING_TRANSACTIONS_EXIST"
        );
        require(
            moneyMarketFund.getShareHoldings(from) > 0,
            "ACCOUNT_HAS_NO_BALANCE"
        );
        uint256 balance = moneyMarketFund.getShareHoldings(from);

        // Effects & Interactions
        IAdminTransfer(address(moneyMarketFund)).transferShares(
            from,
            to,
            balance
        );
        IAccountManager(modules.getModuleAddress(AUTHORIZATION_MODULE))
            .removeAccountPostRecovery(from, to);

        emit AccountRecovered(from, to, balance, memo);
    }

    /**
     * @dev Recovers a part of the balance of an account
     *
     * @param from the account holding the balance amount to recover
     * @param to the destination account to transfer the balance
     * @param memo a memo for the recovery operation
     */
    function recoverAsset(
        address from,
        address to,
        uint256 amount,
        string memory memo
    ) external virtual override onlyAdmin {
        // Checks
        require(
            IAuthorization(modules.getModuleAddress(AUTHORIZATION_MODULE))
                .isAccountAuthorized(from) &&
                IAuthorization(modules.getModuleAddress(AUTHORIZATION_MODULE))
                    .isAccountAuthorized(to),
            "SHAREHOLDER_DOES_NOT_EXIST"
        );

        uint256 balance = moneyMarketFund.getShareHoldings(from);
        require(balance >= amount, "NOT_ENOUGH_BALANCE");

        // Effects & Interactions
        IAdminTransfer(address(moneyMarketFund)).transferShares(
            from,
            to,
            amount
        );

        emit AssetRecovered(from, to, amount, memo);
    }

    // -------------------- Dividends --------------------  //

    function _payDividend(
        address account,
        uint256 dividendShares
    ) internal virtual {
        moneyMarketFund.mintShares(account, dividendShares);
    }

    function _handleNegativeYield(
        address account,
        uint256 balance,
        uint256 dividendShares
    ) internal {
        uint256 negativeYield;
        if (dividendShares < balance) {
            negativeYield = dividendShares;
        } else {
            negativeYield = balance;
        }
        moneyMarketFund.burnShares(account, negativeYield);
    }

    // -------------------- Transactions --------------------  //

    function _processSettlements(
        bytes32[] calldata txIds,
        address account,
        uint256 date,
        uint256 price
    ) internal virtual whenTransactionsExist(account) {
        bytes32[] memory pendingTxs = ITransactionStorage(
            modules.getModuleAddress(TRANSACTIONAL_MODULE)
        ).getAccountTransactions(account);
        for (uint256 i = 0; i < pendingTxs.length; ) {
            bytes32 txId = pendingTxs[i];
            (
                uint8 txType,
                address source,
                address destination,
                uint256 txDate,
                uint256 amount,

            ) = IExtendedTransactionDetail(
                    modules.getModuleAddress(TRANSACTIONAL_MODULE)
                ).getExtendedTransactionDetail(txId);
            require(
                _isTypeSupported(ITransactionStorage.TransactionType(txType)),
                "INVALID_TRANSACTION_TYPE"
            );
            if (txDate <= date) {
                if (
                    _isLiquidation(ITransactionStorage.TransactionType(txType))
                ) {
                    _handleBalanceDecrease(
                        account,
                        date,
                        amount,
                        price,
                        txId,
                        ITransactionStorage.TransactionType(txType)
                    );
                    // remove settled tx from storage
                    ITransactionStorage(
                        modules.getModuleAddress(TRANSACTIONAL_MODULE)
                    ).clearTransactionStorage(account, txId);
                } else if (
                    _isPurchase(ITransactionStorage.TransactionType(txType))
                ) {
                    _handlePurchaseSettlement(
                        txIds,
                        account,
                        date,
                        amount,
                        price,
                        txId,
                        ITransactionStorage.TransactionType(txType)
                    );
                } else if (
                    ITransactionStorage.TransactionType(txType) ==
                    ITransactionStorage.TransactionType.SHARE_TRANSFER
                ) {
                    IAdminTransfer(tokenRegistry.getTokenAddress(tokenId))
                        .transferShares(source, destination, amount);
                    // remove settled tx from storage
                    ITransactionStorage(
                        modules.getModuleAddress(TRANSACTIONAL_MODULE)
                    ).clearTransactionStorage(account, txId);
                    emit TransferSettled(
                        source,
                        destination,
                        date,
                        txType,
                        txId,
                        price,
                        amount // shares
                    );
                }
            }
            unchecked {
                i++;
            }
        }
        ITransactionStorage(modules.getModuleAddress(TRANSACTIONAL_MODULE))
            .unlistFromAccountsWithPendingTransactions(account);
    }

    function _processCXSettlement(
        address account,
        bytes32 requestId,
        uint256 date,
        uint256 price
    ) internal virtual whenTransactionsExist(account) {
        (
            uint8 txType,
            ,
            ,
            uint256 txDate,
            uint256 amount,

        ) = IExtendedTransactionDetail(
                modules.getModuleAddress(TRANSACTIONAL_MODULE)
            ).getExtendedTransactionDetail(requestId);
        require(
            _isTypeSupported(ITransactionStorage.TransactionType(txType)),
            "INVALID_TRANSACTION_TYPE"
        );
        if (txDate <= date) {
            if (
                ITransactionStorage.TransactionType(txType) ==
                ITransactionStorage.TransactionType.CXFER_OUT
            ) {
                _handleBalanceDecrease(
                    account,
                    date,
                    amount,
                    price,
                    requestId,
                    ITransactionStorage.TransactionType(txType)
                );
                ITransactionStorage(
                    modules.getModuleAddress(TRANSACTIONAL_MODULE)
                ).clearTransactionStorage(account, requestId);
            } else if (
                ITransactionStorage.TransactionType(txType) ==
                ITransactionStorage.TransactionType.CXFER_IN
            ) {
                _handleBalanceIncrease(
                    account,
                    date,
                    amount,
                    price,
                    requestId,
                    ITransactionStorage.TransactionType(txType)
                );
                ITransactionStorage(
                    modules.getModuleAddress(TRANSACTIONAL_MODULE)
                ).clearTransactionStorage(account, requestId);
            }
            ITransactionStorage(modules.getModuleAddress(TRANSACTIONAL_MODULE))
                .unlistFromAccountsWithPendingTransactions(account);
        }
    }

    function _processDividends(
        address account,
        uint256 balance,
        uint256 date,
        int256 rate,
        uint256 price
    ) internal virtual {
        require(price > 0, "INVALID_PRICE");
        if (balance > 0) {
            uint256 dividendAmount = balance * uint256(abs(rate));
            uint256 dividendShares = dividendAmount / price;
            uint256 scaleFactor = moneyMarketFund.NUMBER_SCALE_FACTOR();

            // a valid rate for this internal function (rate != 0) is verified
            // in the calling function via the  'onlyWithValidRate' modifier
            bool isNegativeYield;
            if (rate > 0) {
                isNegativeYield = false;
                _payDividend(account, dividendShares);
            } else {
                // handle very unlikely scenario if occurs
                isNegativeYield = true;
                _handleNegativeYield(account, balance, dividendShares);
            }

            emit DividendDistributed(
                account,
                date,
                rate,
                price,
                dividendShares,
                dividendAmount / scaleFactor,
                balance,
                isNegativeYield
            );
        }
    }

    function _handleBalanceDecrease(
        address account,
        uint256 date,
        uint256 amount,
        uint256 price,
        bytes32 txId,
        ITransactionStorage.TransactionType txType
    ) internal virtual {
        uint256 scaleFactor = moneyMarketFund.NUMBER_SCALE_FACTOR();
        if (txType == ITransactionStorage.TransactionType.FULL_LIQUIDATION) {
            uint256 lastBalance = moneyMarketFund.balanceOf(account);
            moneyMarketFund.burnShares(account, lastBalance);
            emit TransactionSettled(
                account,
                date,
                uint8(txType),
                txId,
                price,
                (lastBalance * price) / scaleFactor,
                lastBalance
            );
        } else {
            uint256 shares = _getQuantityOfTokens(scaleFactor, amount, price);
            moneyMarketFund.burnShares(account, shares);
            emit TransactionSettled(
                account,
                date,
                uint8(txType),
                txId,
                price,
                amount,
                shares
            );
        }
    }

    function _handleBalanceIncrease(
        address account,
        uint256 date,
        uint256 amount,
        uint256 price,
        bytes32 txId,
        ITransactionStorage.TransactionType txType
    ) internal virtual {
        uint256 shares = _getQuantityOfTokens(
            moneyMarketFund.NUMBER_SCALE_FACTOR(),
            amount,
            price
        );
        emit TransactionSettled(
            account,
            date,
            uint8(txType),
            txId,
            price,
            amount,
            shares
        );
        moneyMarketFund.mintShares(account, shares);
    }

    function _handlePurchaseSettlement(
        bytes32[] calldata txIds,
        address account,
        uint256 date,
        uint256 amount,
        uint256 price,
        bytes32 txId,
        ITransactionStorage.TransactionType txType
    ) internal virtual whenNotInArray(txIds, txId) {
        _handleBalanceIncrease(account, date, amount, price, txId, txType);
        // remove settled tx from storage
        ITransactionStorage(modules.getModuleAddress(TRANSACTIONAL_MODULE))
            .clearTransactionStorage(account, txId);
    }

    function _isTypeSupported(
        ITransactionStorage.TransactionType txType
    ) internal pure virtual returns (bool) {
        return (txType == ITransactionStorage.TransactionType.AIP ||
            txType == ITransactionStorage.TransactionType.CASH_PURCHASE ||
            txType == ITransactionStorage.TransactionType.CASH_LIQUIDATION ||
            txType == ITransactionStorage.TransactionType.FULL_LIQUIDATION ||
            txType == ITransactionStorage.TransactionType.SHARE_TRANSFER ||
            txType == ITransactionStorage.TransactionType.CXFER_OUT ||
            txType == ITransactionStorage.TransactionType.CXFER_IN);
    }

    function _isPurchase(
        ITransactionStorage.TransactionType txType
    ) internal pure virtual returns (bool) {
        return (txType == ITransactionStorage.TransactionType.AIP ||
            txType == ITransactionStorage.TransactionType.CASH_PURCHASE);
    }

    function _isLiquidation(
        ITransactionStorage.TransactionType txType
    ) internal pure virtual returns (bool) {
        return (txType ==
            ITransactionStorage.TransactionType.CASH_LIQUIDATION ||
            txType == ITransactionStorage.TransactionType.FULL_LIQUIDATION);
    }

    // ------------------------------------------------------------------- //

    function _getQuantityOfTokens(
        uint256 scaleFactor,
        uint256 amount,
        uint256 price
    ) internal pure virtual returns (uint256) {
        return ((amount * scaleFactor) / price);
    }

    function abs(int x) internal pure virtual returns (int) {
        require(x != type(int256).min, "ARITHMETIC_OVERFLOW");
        return x >= 0 ? x : -x;
    }
}
