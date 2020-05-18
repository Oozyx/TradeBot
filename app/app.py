from eth_account import Account
from web3 import Web3, middleware
from web3.gas_strategies.time_based import fast_gas_price_strategy, medium_gas_price_strategy, slow_gas_price_strategy
import os
import time
from requests import Request, Session
from requests.exceptions import ConnectionError, Timeout, TooManyRedirects
import json

# initialize from our Infura provider
# INFURA_ENDPOINT = "https://ropsten.infura.io/v3/baf3c8ecbd384b4daef03573f23c0a30"
# INFURA_ENDPOINT = "https://rinkeby.infura.io/v3/baf3c8ecbd384b4daef03573f23c0a30"
INFURA_ENDPOINT = "https://mainnet.infura.io/v3/baf3c8ecbd384b4daef03573f23c0a30"
w3 = Web3(Web3.HTTPProvider(INFURA_ENDPOINT))
# w3.middleware_onion.inject(middleware.geth_poa_middleware, layer=0) # necessary for Rinkeby only

# set gas price strategy
w3.eth.setGasPriceStrategy(medium_gas_price_strategy)

# CoinMarketCap API key
COIN_MARKET_CAP_KEY = "9924e4f9-55a3-493e-bcaa-66f8fc4c4a5d"

# define the directory of our app so we can use relative paths
appDir = os.path.abspath(os.path.dirname(__file__))

# declare an instance of our contract
tradeBot = None

# constants
DECIMALS_18 = 1000000000000000000
DECIMALS_6  = 1000000
DECIMALS_8  = 100000000
ETH_MOCK_ADDRESS = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"
DAI_ADDRESS      = "0x6B175474E89094C44Da98b954EedeAC495271d0F" # Mainnet
FLASH_LOAN_FEE   = 0.0009
SLEEP_DURATION   = 60 * 1 # 1 minutes
TIME_BUDGET      = SLEEP_DURATION * 50

def log(message):
    with open(os.path.join(appDir, "log"), "a") as logFile:
        logFile.write(message + "\n")

def signAndSendTransaction(tx):
    try:
        txSigned = w3.eth.account.sign_transaction(tx, w3.eth.defaultAccount.privateKey)
        txHash = w3.eth.sendRawTransaction(txSigned.rawTransaction)
        txReceipt = w3.eth.waitForTransactionReceipt(txHash)
        gasFee = tx["gasPrice"] * txReceipt["gasUsed"]

        log("Transaction complete.")
        log("Gas price: " + str(tx["gasPrice"]))
        log("Gas used: " + str(txReceipt["gasUsed"]))
        log("Total gas fee: " + str(gasFee))

        return txReceipt
    
    except Exception as e:
        print(e)

def initializeContract():
    # import our account
    with open(os.path.join(appDir, ".privatekey"), "r") as keyFile:
        myPrivateKey = keyFile.read()
    w3.eth.defaultAccount = w3.eth.account.from_key(myPrivateKey)

    # get contract info if it exists
    global tradeBot
    if os.path.isfile(os.path.join(appDir, ".contractinfo")):
        with open(os.path.join(appDir, ".contractinfo"), "r") as contractInfo:
            abiSaved = contractInfo.readline().strip("\n")
            addressSaved = contractInfo.readline().strip("\n")

        tradeBot = w3.eth.contract(address=addressSaved, abi=abiSaved)
    else:
        # retrieve abi and bytecode
        with open(os.path.join(appDir, "../bin/contracts/TradeBot.abi"), "r") as abiFile:
            abiTradeBot = abiFile.read()

        with open(os.path.join(appDir, "../bin/contracts/TradeBot.bin"), "r") as byteFile:
            byteTradeBot = byteFile.read()

        # deploy the contract
        TradeBot = w3.eth.contract(abi=abiTradeBot, bytecode=byteTradeBot)
        gasPrice = w3.eth.generateGasPrice()
        tx = TradeBot.constructor().buildTransaction({
            "from": w3.eth.defaultAccount.address,
            "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
            "gasPrice": gasPrice,
        })
        txReceipt = signAndSendTransaction(tx)
        
        # retrieve an instance of the contract
        tradeBot = w3.eth.contract(address=txReceipt.contractAddress, abi=abiTradeBot)
        
        # write to file so we don't redeploy if not necessary
        with open(os.path.join(appDir, ".contractinfo"), "w") as contractInfo:
            contractInfo.write(abiTradeBot + "\n")
            contractInfo.write(tradeBot.address + "\n")

def arbExecute(stableCoinAddress, mediatorCoinAddress, amount, dexOrder, gasLimit, gasPrice):
    if dexOrder == "SELL_UNI_BUY_KYB":
        tx = tradeBot.functions.arbSellUniswapBuyKyber(stableCoinAddress, mediatorCoinAddress, amount).buildTransaction({
            "from": w3.eth.defaultAccount.address,
            "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
            "gas": gasLimit,
            "gasPrice": gasPrice,
        })
    if dexOrder == "SELL_KYB_BUY_UNI":
        tx = tradeBot.functions.arbSellKyberBuyUniswap(stableCoinAddress, mediatorCoinAddress, amount).buildTransaction({
            "from": w3.eth.defaultAccount.address,
            "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
            "gas": gasLimit,
            "gasPrice": gasPrice,
        })

    return signAndSendTransaction(tx)

def getAmountOutUniswap(addressFromToken, addressToToken, fromTokenAmount):
    return tradeBot.functions.getAmountOutUniswap(addressFromToken, addressToToken, fromTokenAmount).call({
        "from": w3.eth.defaultAccount.address,
    })

def getAmountOutKyber(addressFromToken, addressToToken, fromTokenAmount):
    rate = tradeBot.functions.getExpectedRateKyber(addressFromToken, addressToToken, fromTokenAmount).call({
        "from": w3.eth.defaultAccount.address,
    })
    return int(fromTokenAmount * (rate / DECIMALS_18))

def depositEth(ethAmount):
    gasPrice = w3.eth.generateGasPrice()
    tx = tradeBot.functions.depositEth().buildTransaction({
        "value": ethAmount,
        "from": w3.eth.defaultAccount.address,
        "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
        "gasPrice": gasPrice,
    })
    signAndSendTransaction(tx)

def depositToken(tokenAddress, tokenAmount):
    # retrieve ERC20 abi
    with open(os.path.join(appDir, "../bin/contracts/ERC20.abi"), "r") as abiFile:
        abiERC20 = abiFile.read()
    
    token = w3.eth.contract(address=tokenAddress, abi=abiERC20)

    # approve the token transfer
    gasPrice = w3.eth.generateGasPrice()
    tx = token.functions.approve(tradeBot.address, tokenAmount).buildTransaction({
        "from": w3.eth.defaultAccount.address,
        "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
        "gasPrice": gasPrice,
    })
    signAndSendTransaction(tx)

    # deposit the token
    gasPrice = w3.eth.generateGasPrice()
    tx = tradeBot.functions.depositToken(tokenAddress, tokenAmount).buildTransaction({
        "from": w3.eth.defaultAccount.address,
        "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
        "gasPrice": gasPrice,
    })
    signAndSendTransaction(tx)

def withdrawEth():
    # build the withdrawal transaction and send it
    gasPrice = w3.eth.generateGasPrice()
    tx = tradeBot.functions.withdrawEth().buildTransaction({
        "from": w3.eth.defaultAccount.address,
        "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
        "gasPrice": gasPrice,
    })
    signAndSendTransaction(tx)

def withdrawToken(tokenAddress):
    estimatedGas = tradeBot.functions.withdraw(tokenAddress).estimateGas({
        "from": w3.eth.defaultAccount.address,
    })
    gasPrice = w3.eth.generateGasPrice()
    tx = tradeBot.functions.withdraw(tokenAddress).buildTransaction({
        "from": w3.eth.defaultAccount.address,
        "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
        "gas": estimatedGas,
        "gasPrice": gasPrice,
    })
    signAndSendTransaction(tx)

def getAPISession():
    headers = {
        "Accepts": "application/json",
        "X-CMC_PRO_API_KEY": COIN_MARKET_CAP_KEY,
    }
    session = Session()
    session.headers.update(headers)
    return session

def getArbitrageProfit(stableCoinAddress, mediatorCoinAddress, loanAmount, dexOrder):
    if dexOrder == "SELL_UNI_BUY_KYB":
        mediatorCoinAmount = getAmountOutUniswap(stableCoinAddress, mediatorCoinAddress, loanAmount)
        netTradeAmount = getAmountOutKyber(mediatorCoinAddress, stableCoinAddress, mediatorCoinAmount)
        
    if dexOrder == "SELL_KYB_BUY_UNI":
        mediatorCoinAmount = getAmountOutKyber(stableCoinAddress, mediatorCoinAddress, loanAmount)
        netTradeAmount = getAmountOutUniswap(mediatorCoinAddress, stableCoinAddress, mediatorCoinAmount)

    log(dexOrder + " net trade amount: " + str(netTradeAmount))

    if (netTradeAmount > loanAmount):
        log("Profitable Trade! Profit: " + str(netTradeAmount - loanAmount))
        return (netTradeAmount - loanAmount)
    else:
        return 0

def getGasFeeUSD(session, gasFeeWEI):
    url = "https://pro-api.coinmarketcap.com/v1/cryptocurrency/quotes/latest"
    parameters = {
        "slug":"ethereum"
    }

    try:
        response = session.get(url, params=parameters)
        data = json.loads(response.text)
        priceETH = data["data"]["1027"]["quote"]["USD"]["price"]
        return priceETH * (gasFeeWEI / DECIMALS_18)
    except (ConnectionError, Timeout, TooManyRedirects) as e:
        print(e)


def main():
    try:
        initializeContract()
    except ValueError as e:
        print(e)
        exit()

    # set which assets and amounts we want to trade with
    stableCoinAddress = ETH_MOCK_ADDRESS
    mediatorCoinAddresses = {
        "LEND": "0x514910771AF9Ca656af840dff83E8264EcF986CA",
        "KNC": "0xdd974D5C2e2928deA5F71b9825b8b646686BD200",
        "MKR": "0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2",
        "ZRX": "0xE41d2489571d322189246DaFA5ebDe1F4699F498",
        "DAI": "0x6B175474E89094C44Da98b954EedeAC495271d0F",
        "SNX": "0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F",
        "BNT": "0x1F573D6Fb3F13d689FF844B4cE37794d79a7FF1C",
        "WETH": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
        "LINK": "0x514910771AF9Ca656af840dff83E8264EcF986CA",
        "BAT": "0x0D8775F648430679A709E98d2b0Cb6250d2887EF"
    }
    # mediatorCoinAddress = "0x514910771AF9Ca656af840dff83E8264EcF986CA"
    loanAmount = 1 * DECIMALS_18

    searchForArb = True
    timeBudget = TIME_BUDGET
    while (searchForArb):
        # get gas price
        # gasPrice = w3.eth.generateGasPrice()
        gasPrice = 10000000000
        estimatedGas = 550000

        # calculate the gas fee 
        gasFeeWei = estimatedGas * gasPrice

        log("Gas fee Wei: " + str(gasFeeWei))

        for coin in mediatorCoinAddresses:
            # for every dex order calculate potential profit and execute if greater than gas fee
            log(coin)
            profit = getArbitrageProfit(stableCoinAddress, mediatorCoinAddresses[coin], loanAmount, "SELL_UNI_BUY_KYB")
            if profit > gasFeeWei:
                # arbExecute(stableCoinAddress, mediatorCoinAddresses[coin], loanAmount, "SELL_UNI_BUY_KYB", estimatedGas, gasPrice)
                log("Trade made!")
                searchForArb = False

            profit = getArbitrageProfit(stableCoinAddress, mediatorCoinAddresses[coin], loanAmount, "SELL_KYB_BUY_UNI")
            if profit > gasFeeWei:
                # arbExecute(stableCoinAddress, mediatorCoinAddresses[coin], loanAmount, "SELL_KYB_BUY_UNI", estimatedGas, gasPrice)
                log("Trade made!")
                searchForArb = False
        
        log("")
        timeBudget = timeBudget - SLEEP_DURATION
        # if (timeBudget == 0):
        #     searchForArb = False
        time.sleep(SLEEP_DURATION)


if __name__ == "__main__":
    main()

    # try:
    #     initializeContract()
    # except ValueError as e:
    #     print(e)
    #     exit()
    
    # withdrawEth()
    # depositEth(DECIMALS_18)


