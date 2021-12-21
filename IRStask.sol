pragma solidity ^0.8.0;

import "https://github.com/aave/protocol-v2/blob/ice/mainnet-deployment-03-12-2020/contracts/protocol/configuration/LendingPoolAddressesProvider.sol";
import "https://github.com/aave/protocol-v2/blob/ice/mainnet-deployment-03-12-2020/contracts/protocol/lendingpool/LendingPool.sol";

contract IRS {
    
    struct Offer {
        uint notional;
        uint duration;
        uint period;
    }

    LendingPoolAddressesProvider private provider;
    LendingPool private lendingPool;
    address private usdc;

    address payable varTaker;
    address payable fixTaker;
    uint private notional;
    uint private duration;
    uint private created;
    uint private period;

    uint private currentPeriod;
    uint private periodCounter;
    bool[2] private paid;
    bool private paymentComplete;
    Offer private offer;

    uint private fixedRate;
    uint private variableRate;

    uint private constant INTEREST_RATE_DIVISOR = 10000;
    uint private constant LIQUIDATION_PENALTY = 50;

    mapping(address => uint256) payment;

    modifier onlyParties {
        require(msg.sender == varTaker || msg.sender == fixTaker);
        _;
    }

    event Initiated(address party, bytes1 role);
    event Accepted(address party, bytes1 role);
    event PaidInstalment(address party);
    event Cancelled(address party);
    event Settled(address party);
    event Liquidated(address party);

    constructor(address _provider, address _usdc, uint _fixedRate) public {
        provider = LendingPoolAddressesProvider(_provider);
        usdc = _usdc;
        lendingPool = LendingPool(provider.getLendingPool());

        fixedRate = _fixedRate;
    }

    function initiateContract(uint _notional, uint _duration, uint _period, bytes1 _role) external payable {
        require(msg.value == _notional/10);
        if (varTaker == address(0) && fixTaker == address(0)) {
            if (_role == "V") {
                varTaker = msg.sender;
                offer = Offer(_notional, _duration, _period);
                emit Initiated(varTaker, "V");
            } else if (_role == "F") {
                fixTaker = msg.sender;
                offer = Offer(_notional, _duration, _period);
                emit Initiated(fixTaker, "F");
            } else {
                revert("Invalid role");
            }
        } else if (varTaker != address(0) && fixTaker == address(0)) {
            if (_role == "V") {
                revert("IRS in progress");
            } else if (_role == "F") {
                require(offer.notional == _notional && offer.duration == _duration && offer.period == _period);
                fixTaker = msg.sender;

                notional = _notional;
                duration = _duration;
                period = _period;
                created = now;
                currentPeriod = now;
                periodCounter = 0;
                paid = [false, false];

                payment[fixTaker] += notional/10;
                payment[varTaker] += notional/10;
                emit Accepted(fixTaker, "F");
            } else {
                revert("Invalid role");
            }
        } else if (varTaker == address(0) && fixTaker != address(0)) {
            if (_role == "V") {
                require(offer.notional == _notional && offer.duration == _duration && offer.period == _period);
                varTaker = msg.sender;

                notional = _notional;
                duration = _duration;
                period = _period;
                created = now;
                currentPeriod = now;
                periodCounter = 0;
                paid = [false, false];

                payment[varTaker] += notional/10;
                payment[fixTaker] += notional/10;
                emit Accepted(varTaker, "V");
            } else if (_role == "F") {
                revert("IRS in progress");
            } else {
                revert("Invalid role");
            }
        } else if (varTaker != address(0) && fixTaker != address(0)) {
            revert("You are not a party in the current IRS");
        }
    }

    function payInstalment() external onlyParties payable {
        require(now <= currentPeriod + period);
        updateVariableRate();
        if (msg.sender == varTaker) {
            require(msg.value == (notional * variableRate)/INTEREST_RATE_DIVISOR);
            payment[varTaker] += msg.value;
            paid[0] = true;
            emit PaidInstalment(varTaker);
        } else if (msg.sender == fixTaker) {
            require(msg.value == (notional * fixedRate)/INTEREST_RATE_DIVISOR);
            payment[fixTaker] += msg.value;
            paid[1] = true;
            emit PaidInstalment(fixTaker);
        } if (paid[0] == true && paid[1] == true) {
            paid[0] = false;
            paid[1] = false;
            currentPeriod = now;
            periodCounter++;
        } if (periodCounter == duration/period) {
            paymentComplete = true;
        }
    }

    function cancelContract() external onlyParties {
        require(now > currentPeriod + period);
        if (msg.sender == varTaker) {
            require(paid[1] == false);
        } else if (msg.sender == fixTaker) {
            require(paid[0] == false);
        }

        uint owedV = payment[varTaker];
        payment[varTaker] = 0;
        uint owedF = payment[fixTaker];
        payment[fixTaker] = 0;

        varTaker.transfer(owedV);
        fixTaker.transfer(owedF);

        varTaker = address(0);
        fixTaker = address(0);
        emit Cancelled(msg.sender);
    }

    function settleContract() external onlyParties {
        require(now >= created + duration && paymentComplete == true);

        uint owedV = payment[fixTaker];
        payment[fixTaker] = 0;
        uint owedF = payment[varTaker];
        payment[varTaker] = 0;
        paymentComplete = false;

        varTaker.transfer(owedV);
        fixTaker.transfer(owedF);

        varTaker = address(0);
        fixTaker = address(0);
        emit Settled(msg.sender);
    }


    function liquidateContract() external onlyParties {
        require(payment[varTaker] < (notional/100)*7 || payment[fixTaker] < (notional/100)*7);
        require(paymentComplete == false);

        uint owedV = payment[varTaker];
        payment[varTaker] = 0;
        uint owedF = payment[fixTaker];
        payment[fixTaker] = 0;

        if (payment[varTaker] < (notional/100)*7 && payment[fixTaker] >= (notional/100)*7) {
            owedF += (owedV/100)*LIQUIDATION_PENALTY;
            owedV -= (owedV/100)*LIQUIDATION_PENALTY;
            emit Liquidated(varTaker);
        } else if (payment[varTaker] >= (notional/100)*7 && payment[fixTaker] < (notional/100)*7) {
            owedV += (owedF/100)*LIQUIDATION_PENALTY;
            owedF -= (owedF/100)*LIQUIDATION_PENALTY;
            emit Liquidated(fixTaker);
        }

        varTaker.transfer(owedV);
        fixTaker.transfer(owedF);

        varTaker = address(0);
        fixTaker = address(0);
    }

    function updateVariableRate() public {
        ( , , , , uint v, , , , , , , ) = lendingPool.getReserveData(usdc); 
        variableRate = v;
    }

}