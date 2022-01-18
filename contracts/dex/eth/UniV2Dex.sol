// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.7.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "../../lib/TransferHelper.sol";
import "../../lib/DexData.sol";
import "../../lib/Utils.sol";

contract UniV2Dex {
    using SafeMath for uint;
    using Utils for uint;
    using TransferHelper for IERC20;

    struct V2PriceOracle {
        uint32 blockTimestampLast;  // Last block timestamp when price updated
        uint price0; // recorded price for token0
        uint price1; // recorded price for token1
        uint price0CumulativeLast; // Cumulative TWAP for token0
        uint price1CumulativeLast; // Cumulative TWAP for token1
    }

    function uniV2Sell(IUniswapV2Factory factory,
        address buyToken,
        address sellToken,
        uint sellAmount,
        uint minBuyAmount,
        address payer,
        address payee
    ) internal returns (uint buyAmount){
        address pair = getUniV2ClassPair(buyToken, sellToken, factory);
        (uint256 token0Reserves, uint256 token1Reserves,) = IUniswapV2Pair(pair).getReserves();
        uint amountReceivedByUniV2 = transferOut(IERC20(sellToken), payer, pair, sellAmount);
        uint balanceBefore = IERC20(buyToken).balanceOf(payee);

        if (buyToken < sellToken) {
            buyAmount = getAmountOut(amountReceivedByUniV2, token1Reserves, token0Reserves);
            IUniswapV2Pair(pair).swap(buyAmount, 0, payee, "");
        } else {
            buyAmount = getAmountOut(amountReceivedByUniV2, token0Reserves, token1Reserves);
            IUniswapV2Pair(pair).swap(0, buyAmount, payee, "");
        }
        
        require(buyAmount >= minBuyAmount, 'buy amount less than min');
        uint bought = IERC20(buyToken).balanceOf(payee).sub(balanceBefore);
        require(buyAmount <= bought, "wrong amount bought");
        return bought;
    }

    function uniV2SellMul(IUniswapV2Factory factory, uint sellAmount, uint minBuyAmount, address[] memory tokens)
    internal returns (uint buyAmount){
        for (uint i = 1; i < tokens.length; i++) {
            address sellToken = tokens[i - 1];
            address buyToken = tokens[i];
            bool isLast = i == tokens.length - 1;
            address payer = i == 1 ? msg.sender : address(this);
            address payee = isLast ? msg.sender : address(this);
            buyAmount = uniV2Sell(factory, buyToken, sellToken, sellAmount, 0, payer, payee);
            if (!isLast) {
                sellAmount = buyAmount;
            }
        }
        require(buyAmount >= minBuyAmount, 'buy amount less than min');
    }

    function uniV2Buy(
        IUniswapV2Factory factory, 
        address buyToken, 
        address sellToken, 
        uint buyAmount, 
        uint maxSellAmount, 
        uint24 buyTokenFeeRate,
        uint24 sellTokenFeeRate
    )internal returns (uint sellAmount){
        address payer = msg.sender;
        address pair = getUniV2ClassPair(buyToken, sellToken, factory);
        (uint256 token0Reserves, uint256 token1Reserves,) = IUniswapV2Pair(pair).getReserves();
        uint balanceBefore = IERC20(buyToken).balanceOf(payer);

       if (buyToken < sellToken) {
            sellAmount = getAmountIn(buyAmount.toAmountBeforeTax(buyTokenFeeRate), token1Reserves, token0Reserves);
            sellAmount = sellAmount.toAmountBeforeTax(sellTokenFeeRate);
            require(sellAmount <= maxSellAmount, 'sell amount not enough');
            transferOut(IERC20(sellToken), payer, pair, sellAmount);
            IUniswapV2Pair(pair).swap(buyAmount, 0, payer, "");
        } else {
            sellAmount = getAmountIn(buyAmount.toAmountBeforeTax(buyTokenFeeRate), token0Reserves, token1Reserves);
            sellAmount = sellAmount.toAmountBeforeTax(sellTokenFeeRate);
            require(sellAmount <= maxSellAmount, 'sell amount not enough');
            transferOut(IERC20(sellToken), payer, pair, sellAmount);
            IUniswapV2Pair(pair).swap(0, buyAmount, payer, "");
        }
            
        uint balanceAfter = IERC20(buyToken).balanceOf(payer);
        require(buyAmount <= balanceAfter.sub(balanceBefore), "wrong amount bought");
    }

    function uniV2CalBuyAmount(IUniswapV2Factory factory, address buyToken, address sellToken, uint sellAmount) internal view returns (uint) {
        address pair = getUniV2ClassPair(buyToken, sellToken, factory);
        (uint256 token0Reserves, uint256 token1Reserves,) = IUniswapV2Pair(pair).getReserves();
        bool isToken0 = buyToken < sellToken;
        if (isToken0) {
            return getAmountOut(sellAmount, token1Reserves, token0Reserves);
        } else {
            return getAmountOut(sellAmount, token0Reserves, token1Reserves);
        }
    }

    function uniV2CalSellAmount(
        IUniswapV2Factory factory, 
        address buyToken, 
        address sellToken, 
        uint buyAmount,
        uint24 buyTokenFeeRate,
        uint24 sellTokenFeeRate
    ) internal view returns (uint sellAmount) {
        address pair = getUniV2ClassPair(buyToken, sellToken, factory);
        (uint256 token0Reserves, uint256 token1Reserves,) = IUniswapV2Pair(pair).getReserves();
        sellAmount = buyToken < sellToken ?
            getAmountIn(buyAmount.toAmountBeforeTax(buyTokenFeeRate), token1Reserves, token0Reserves) :
            getAmountIn(buyAmount.toAmountBeforeTax(buyTokenFeeRate), token0Reserves, token1Reserves);
        
        return sellAmount.toAmountBeforeTax(sellTokenFeeRate);
    }
    
    function uniV2GetPrice(IUniswapV2Factory factory, address desToken, address quoteToken, uint8 decimals) internal view returns (uint256){
        address pair = getUniV2ClassPair(desToken, quoteToken, factory);
        (uint256 token0Reserves, uint256 token1Reserves,) = IUniswapV2Pair(pair).getReserves();
        return desToken == IUniswapV2Pair(pair).token0() ?
        token1Reserves.mul(10 ** decimals).div(token0Reserves) :
        token0Reserves.mul(10 ** decimals).div(token1Reserves);
    }

    function uniV2GetAvgPrice(address desToken, address quoteToken, V2PriceOracle memory priceOracle) internal pure returns (uint256 price, uint256 timestamp){
        timestamp = priceOracle.blockTimestampLast;
        price = desToken < quoteToken ? uint(priceOracle.price0) : uint(priceOracle.price1);
    }


    function uniV2GetPriceCAvgPriceHAvgPrice(address pair, V2PriceOracle memory priceOracle, address desToken, address quoteToken, uint8 decimals)
    internal view returns (uint price, uint cAvgPrice, uint256 hAvgPrice, uint256 timestamp){
        bool isToken0 = desToken < quoteToken;
        (uint256 token0Reserves, uint256 token1Reserves, uint32 uniBlockTimeLast) = IUniswapV2Pair(pair).getReserves();
        price = isToken0 ?
        token1Reserves.mul(10 ** decimals).div(token0Reserves) :
        token0Reserves.mul(10 ** decimals).div(token1Reserves);

        hAvgPrice = isToken0 ? uint(priceOracle.price0) : uint(priceOracle.price1);
        timestamp = priceOracle.blockTimestampLast;

        if (uniBlockTimeLast <= priceOracle.blockTimestampLast) {
            cAvgPrice = hAvgPrice;
        } else {
            uint32 timeElapsed = uniBlockTimeLast - priceOracle.blockTimestampLast;
            cAvgPrice = uint256(isToken0 ?
                calTPrice(IUniswapV2Pair(pair).price0CumulativeLast(), priceOracle.price0CumulativeLast, timeElapsed, decimals) :
                calTPrice(IUniswapV2Pair(pair).price1CumulativeLast(), priceOracle.price1CumulativeLast, timeElapsed, decimals));
        }
    }

    function uniV2UpdatePriceOracle(address pair, V2PriceOracle memory priceOracle, uint32 timeWindow, uint8 decimals) internal returns (V2PriceOracle memory, bool updated) {
        uint32 currentBlockTime = toUint32(block.timestamp);
        if (currentBlockTime < (priceOracle.blockTimestampLast + timeWindow)) {
            return (priceOracle, false);
        }
        (,,uint32 uniBlockTimeLast) = IUniswapV2Pair(pair).getReserves();
        if (uniBlockTimeLast != currentBlockTime) {
            IUniswapV2Pair(pair).sync();
        }
        uint32 timeElapsed = currentBlockTime - priceOracle.blockTimestampLast;
        uint currentPrice0CumulativeLast = IUniswapV2Pair(pair).price0CumulativeLast();
        uint currentPrice1CumulativeLast = IUniswapV2Pair(pair).price1CumulativeLast();
        if (priceOracle.blockTimestampLast != 0) {
            priceOracle.price0 = calTPrice(currentPrice0CumulativeLast, priceOracle.price0CumulativeLast, timeElapsed, decimals);
            priceOracle.price1 = calTPrice(currentPrice1CumulativeLast, priceOracle.price1CumulativeLast, timeElapsed, decimals);
        }
        priceOracle.price0CumulativeLast = currentPrice0CumulativeLast;
        priceOracle.price1CumulativeLast = currentPrice1CumulativeLast;
        priceOracle.blockTimestampLast = currentBlockTime;
        return (priceOracle, true);
    }

    function calTPrice(uint currentPriceCumulativeLast, uint historyPriceCumulativeLast, uint32 timeElapsed, uint8 decimals)
    internal pure returns (uint){
        return ((currentPriceCumulativeLast.sub(historyPriceCumulativeLast).mul(10 ** decimals)) >> 112).div(timeElapsed);
    }

    function toUint32(uint256 y) internal pure returns (uint32 z) {
        require((z = uint32(y)) == y);
    }

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) private pure returns (uint amountOut)
    {
        require(amountIn > 0, 'INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'INSUFFICIENT_LIQUIDITY');
        uint amountInWithFee = amountIn.mul(997);
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) public  pure returns (uint amountIn) {
        require(amountOut > 0, 'INSUFFICIENT_OUTPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'INSUFFICIENT_LIQUIDITY');
        uint numerator = reserveIn.mul(amountOut).mul(1000);
        uint denominator = reserveOut.sub(amountOut).mul(997);
        amountIn = (numerator / denominator).add(1);
    }

    function transferOut(IERC20 token, address payer, address to, uint amount) private returns (uint256 amountReceived) {
        if (payer == address(this)) {
            amountReceived = token.safeTransfer(to, amount);
        } else {
            amountReceived = token.safeTransferFrom(payer, to, amount);
        }
    }

    function getUniV2ClassPair(address tokenA, address tokenB, IUniswapV2Factory factory) internal view returns (address pair){
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (address(factory) == 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f) {
            return address(uint(keccak256(abi.encodePacked(
                    hex'ff',
                    address(factory),
                    keccak256(abi.encodePacked(token0, token1)),
                    hex'96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f'
                ))));
        } else {
            return factory.getPair(tokenA, tokenB);
        }
    }
}
