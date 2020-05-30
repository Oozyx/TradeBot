from eth_account import Account
from web3 import Web3, middleware
from web3.gas_strategies.time_based import fast_gas_price_strategy, medium_gas_price_strategy
import os
import time
from requests import Request, Session
from requests.exceptions import ConnectionError, Timeout, TooManyRedirects
import json
from threading import Thread 
import winsound

# initialize from our Infura provider
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
DECIMALS_18      = 1000000000000000000
ETH_MOCK_ADDRESS = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"
DAI_ADDRESS      = "0xaD6D458402F60fD3Bd25163575031ACDce07538D" # Ropsten
FLASH_LOAN_FEE   = 0.0009
SLEEP_DURATION   = 30

# set which assets and amounts we want to trade with
gasPrice = None
stableCoinAddress = ETH_MOCK_ADDRESS
mediatorCoinAddresses = {
    "LEND": "0x80fB784B7eD66730e8b1DBd9820aFD29931aab03",
    "KNC": "0xdd974D5C2e2928deA5F71b9825b8b646686BD200",
    "MKR": "0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2",
    "ZRX": "0xE41d2489571d322189246DaFA5ebDe1F4699F498",
    "DAI": "0x6B175474E89094C44Da98b954EedeAC495271d0F",
    "SNX": "0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F",
    "BNT": "0x1F573D6Fb3F13d689FF844B4cE37794d79a7FF1C",
    "WETH": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    "LINK": "0x514910771AF9Ca656af840dff83E8264EcF986CA",
    "BAT": "0x0D8775F648430679A709E98d2b0Cb6250d2887EF",
    "REN": "0x408e41876cCCDC0F92210600ef50372656052a38",
    "RSR": "0x8762db106B2c2A0bccB3A80d1Ed41273552616E8"
}
loanAmount = 1 * DECIMALS_18
isFlashLoan = False

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
        
        # make sure it matches most recent build
        with open(os.path.join(appDir, "../bin/contracts/TradeBot.abi"), "r") as abiFile:
            abiBuild = abiFile.read()

        if abiBuild != abiSaved:
            raise ValueError("Latest contract build does not matched latest deployed. Rebuild contract and delete saved contract info file.")

        tradeBot = w3.eth.contract(address=addressSaved, abi=abiSaved)
    else:
        # retrieve abi and bytecode
        with open(os.path.join(appDir, "../bin/contracts/TradeBot.abi"), "r") as abiFile:
            abiTradeBot = abiFile.read()

        with open(os.path.join(appDir, "../bin/contracts/TradeBot.bin"), "r") as byteFile:
            byteTradeBot = byteFile.read()

        # deploy the contract
        TradeBot = w3.eth.contract(abi=abiTradeBot, bytecode=byteTradeBot)
        estimatedGas = TradeBot.constructor().estimateGas({
            "from": w3.eth.defaultAccount.address,
        })
        gasPrice = w3.eth.generateGasPrice()
        tx = TradeBot.constructor().buildTransaction({
            "from": w3.eth.defaultAccount.address,
            "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
            "gas": estimatedGas,
            "gasPrice": gasPrice,
        })
        txReceipt = signAndSendTransaction(tx)
        
        # retrieve an instance of the contract
        tradeBot = w3.eth.contract(address=txReceipt.contractAddress, abi=abiTradeBot)
        
        # write to file so we don't redeploy if not necessary
        with open(os.path.join(appDir, ".contractinfo"), "w") as contractInfo:
            contractInfo.write(abiTradeBot + "\n")
            contractInfo.write(tradeBot.address + "\n")

def arbExecuteNoLoan(stableCoinAddress, mediatorCoinAddress, amount, dexOrder, gasTokenAmount, gasLimit, gasPrice):
    tx = tradeBot.functions.arbExecuteBase(stableCoinAddress, mediatorCoinAddress, amount, dexOrder, gasTokenAmount).buildTransaction({
        "from": w3.eth.defaultAccount.address,
        "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
        "gas": gasLimit,
        "gasPrice": gasPrice,
    })
    return signAndSendTransaction(tx)

def arbExecute(stableCoinAddress, mediatorCoinAddress, amount, dexOrder, gasTokenAmount, gasLimit, gasPrice):
    tx = tradeBot.functions.arbExecute(stableCoinAddress, mediatorCoinAddress, amount, dexOrder, gasTokenAmount).buildTransaction({
        "from": w3.eth.defaultAccount.address,
        "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
        "gas": gasLimit,
        "gasPrice": gasPrice,
    })
    return signAndSendTransaction(tx)

def getAmountOutUniswapV1(addressFromToken, addressToToken, fromTokenAmount):
    return tradeBot.functions.getAmountOutUniswapV1(addressFromToken, addressToToken, fromTokenAmount).call({
        "from": w3.eth.defaultAccount.address,
    })

def getAmountOutUniswapV2(addressFromToken, addressToToken, fromTokenAmount):
    return tradeBot.functions.getAmountOutUniswapV2(addressFromToken, addressToToken, fromTokenAmount).call({
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
    gasPrice = w3.eth.generateGasPrice()
    tx = tradeBot.functions.withdraw(tokenAddress).buildTransaction({
        "from": w3.eth.defaultAccount.address,
        "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
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

def getArbitrageProfit(stableCoinAddress, mediatorCoinAddress, loanAmount, dexOrder, isFlashLoan):
    if dexOrder == "SELL_UV1_BUY_KYB":
        mediatorCoinAmount = getAmountOutUniswapV1(stableCoinAddress, mediatorCoinAddress, loanAmount)
        netTradeAmount = getAmountOutKyber(mediatorCoinAddress, stableCoinAddress, mediatorCoinAmount)
        
    if dexOrder == "SELL_UV1_BUY_UV2":
        mediatorCoinAmount = getAmountOutUniswapV1(stableCoinAddress, mediatorCoinAddress, loanAmount)
        netTradeAmount = getAmountOutUniswapV2(mediatorCoinAddress, stableCoinAddress, mediatorCoinAmount)

    if dexOrder == "SELL_KYB_BUY_UV1":
        mediatorCoinAmount = getAmountOutKyber(stableCoinAddress, mediatorCoinAddress, loanAmount)
        netTradeAmount = getAmountOutUniswapV1(mediatorCoinAddress, stableCoinAddress, mediatorCoinAmount)

    if dexOrder == "SELL_KYB_BUY_UV2":
        mediatorCoinAmount = getAmountOutKyber(stableCoinAddress, mediatorCoinAddress, loanAmount)
        netTradeAmount = getAmountOutUniswapV2(mediatorCoinAddress, stableCoinAddress, mediatorCoinAmount)

    if dexOrder == "SELL_UV2_BUY_KYB":
        mediatorCoinAmount = getAmountOutUniswapV2(stableCoinAddress, mediatorCoinAddress, loanAmount)
        netTradeAmount = getAmountOutKyber(mediatorCoinAddress, stableCoinAddress, mediatorCoinAmount)
    
    if dexOrder == "SELL_UV2_BUY_UV1":
        mediatorCoinAmount = getAmountOutUniswapV2(stableCoinAddress, mediatorCoinAddress, loanAmount)
        netTradeAmount = getAmountOutUniswapV1(mediatorCoinAddress, stableCoinAddress, mediatorCoinAmount)

    log(dexOrder + " net trade amount: " + str(netTradeAmount))

    if isFlashLoan == True:
        if (netTradeAmount > loanAmount * (FLASH_LOAN_FEE + 1)):
            log("Profitable Trade! Profit: " + str(netTradeAmount - loanAmount * (FLASH_LOAN_FEE + 1)))
            return (netTradeAmount - loanAmount * (FLASH_LOAN_FEE + 1))
    else:
        if (netTradeAmount > loanAmount):
            log("Profitable Trade! Profit: " + str(netTradeAmount - loanAmount))
            return (netTradeAmount - loanAmount)
    
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

def updateGasPrice():
    while (True):
        global gasPrice
        tempGasPrice = w3.eth.generateGasPrice()
        gasPrice = tempGasPrice
        time.sleep(60 * 3)

def main():
    try:
        initializeContract()
    except ValueError as e:
        print(e)
        exit()

    # initialize API consumption
    # session = getAPISession()

    global gasPrice
    gasPrice = w3.eth.generateGasPrice()
    # start the thread to update gas price
    thread = Thread(target=updateGasPrice)
    thread.start()

    searchForArb = True
    while (searchForArb):
        # get estimated gas
        estimatedGas = 550000
        
        # calculate the gas fee
        gasTokenAmount = 0
        if gasPrice >= 45000000000: # at this price it becomes a good idea to use our gas tokens
            gasTokenAmount = 1
            gasFeeWei = int(estimatedGas / 2) * gasPrice
        else:
            gasFeeWei = estimatedGas * gasPrice

        log("Gas fee Wei: " + str(gasFeeWei))

        for coin in mediatorCoinAddresses:
            # for every dex order calculate potential profit and execute if greater than gas fee
            log(coin)
            profit = getArbitrageProfit(stableCoinAddress, mediatorCoinAddresses[coin], loanAmount, "SELL_UV1_BUY_KYB", isFlashLoan)
            if profit > gasFeeWei:
                arbExecute(stableCoinAddress, mediatorCoinAddresses[coin], loanAmount, "SELL_UV1_BUY_KYB", gasTokenAmount, estimatedGas, gasPrice)
                log("Trade made!")
                duration = 1000  # milliseconds
                freq = 440  # Hz
                winsound.Beep(freq, duration)
                searchForArb = False

            profit = getArbitrageProfit(stableCoinAddress, mediatorCoinAddresses[coin], loanAmount, "SELL_UV1_BUY_UV2", isFlashLoan)
            if profit > gasFeeWei:
                arbExecute(stableCoinAddress, mediatorCoinAddresses[coin], loanAmount, "SELL_UV1_BUY_UV2", gasTokenAmount, estimatedGas, gasPrice)
                log("Trade made!")
                duration = 1000  # milliseconds
                freq = 440  # Hz
                winsound.Beep(freq, duration)
                searchForArb = False

            profit = getArbitrageProfit(stableCoinAddress, mediatorCoinAddresses[coin], loanAmount, "SELL_KYB_BUY_UV1", isFlashLoan)
            if profit > gasFeeWei:
                arbExecute(stableCoinAddress, mediatorCoinAddresses[coin], loanAmount, "SELL_KYB_BUY_UV1", gasTokenAmount, estimatedGas, gasPrice)
                log("Trade made!")
                duration = 1000  # milliseconds
                freq = 440  # Hz
                winsound.Beep(freq, duration)
                searchForArb = False
            
            profit = getArbitrageProfit(stableCoinAddress, mediatorCoinAddresses[coin], loanAmount, "SELL_KYB_BUY_UV2", isFlashLoan)
            if profit > gasFeeWei:
                arbExecute(stableCoinAddress, mediatorCoinAddresses[coin], loanAmount, "SELL_KYB_BUY_UV2", gasTokenAmount, estimatedGas, gasPrice)
                log("Trade made!")
                duration = 1000  # milliseconds
                freq = 440  # Hz
                winsound.Beep(freq, duration)
                searchForArb = False
            
            profit = getArbitrageProfit(stableCoinAddress, mediatorCoinAddresses[coin], loanAmount, "SELL_UV2_BUY_UV1", isFlashLoan)
            if profit > gasFeeWei:
                arbExecute(stableCoinAddress, mediatorCoinAddresses[coin], loanAmount, "SELL_UV2_BUY_UV1", gasTokenAmount, estimatedGas, gasPrice)
                log("Trade made!")
                duration = 1000  # milliseconds
                freq = 440  # Hz
                winsound.Beep(freq, duration)
                searchForArb = False
            
            profit = getArbitrageProfit(stableCoinAddress, mediatorCoinAddresses[coin], loanAmount, "SELL_UV2_BUY_KYB", isFlashLoan)
            if profit > gasFeeWei:
                arbExecute(stableCoinAddress, mediatorCoinAddresses[coin], loanAmount, "SELL_UV2_BUY_KYB", gasTokenAmount, estimatedGas, gasPrice)
                log("Trade made!")
                duration = 1000  # milliseconds
                freq = 440  # Hz
                winsound.Beep(freq, duration)
                searchForArb = False
        
        log("")
        time.sleep(SLEEP_DURATION)


if __name__ == "__main__":
    # main()
    try:
        initializeContract()
    except ValueError as e:
        print(e)
        exit()

    
