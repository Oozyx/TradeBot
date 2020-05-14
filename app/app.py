from eth_account import Account
from web3 import Web3, middleware
from web3.gas_strategies.time_based import fast_gas_price_strategy
import os
import time
from requests import Request, Session
from requests.exceptions import ConnectionError, Timeout, TooManyRedirects
import json

# initialize from our Infura provider
INFURA_ENDPOINT = "https://ropsten.infura.io/v3/baf3c8ecbd384b4daef03573f23c0a30"
w3 = Web3(Web3.HTTPProvider(INFURA_ENDPOINT))
# w3.middleware_onion.inject(middleware.geth_poa_middleware, layer=0) # necessary for Rinkeby only

# set gas price strategy
w3.eth.setGasPriceStrategy(fast_gas_price_strategy)

# CoinMarketCap API key
COIN_MARKET_CAP_KEY = "9924e4f9-55a3-493e-bcaa-66f8fc4c4a5d"

# define the directory of our app so we can use relative paths
appDir = os.path.abspath(os.path.dirname(__file__))

# declare an instance of our contract
tradeBot = None

# constants
DECIMALS_18 = 1000000000000000000
ETH_MOCK_ADDRESS = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"
DAI_ADDRESS      = "0xaD6D458402F60fD3Bd25163575031ACDce07538D" # Ropsten
FLASH_LOAN_FEE   = 0.0009

def signAndSendTransaction(tx):
    try:
        txSigned = w3.eth.account.sign_transaction(tx, w3.eth.defaultAccount.privateKey)
        txHash = w3.eth.sendRawTransaction(txSigned.rawTransaction)
        txReceipt = w3.eth.waitForTransactionReceipt(txHash)
        gasFee = tx["gasPrice"] * txReceipt["gasUsed"]

        print("Transaction complete.")
        print("Gas price: " + str(tx["gasPrice"]))
        print("Gas used: " + str(txReceipt["gasUsed"]))
        print("Total gas fee: " + str(gasFee) + "\n")

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
        # estimatedGas = TradeBot.constructor().estimateGas({
        #     "from": w3.eth.defaultAccount.address,
        # })
        gasPrice = w3.eth.generateGasPrice()
        tx = TradeBot.constructor().buildTransaction({
            "from": w3.eth.defaultAccount.address,
            "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
            # "gas": estimatedGas,
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
    tx = tradeBot.functions.arbExecute(stableCoinAddress, mediatorCoinAddress, amount, dexOrder).buildTransaction({
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
    return tradeBot.functions.getAmountOutKyber(addressFromToken, addressToToken, fromTokenAmount).call({
        "from": w3.eth.defaultAccount.address,
    })

def depositEth(ethAmount):
    # estimatedGas = tradeBot.functions.depositEth().estimateGas({
    #     "from": w3.eth.defaultAccount.address,
    # })
    gasPrice = w3.eth.generateGasPrice()
    tx = tradeBot.functions.depositEth().buildTransaction({
        "value": ethAmount,
        "from": w3.eth.defaultAccount.address,
        "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
        # "gas": estimatedGas,
        "gasPrice": gasPrice,
    })
    signAndSendTransaction(tx)

def depositToken(tokenAddress, tokenAmount):
    # retrieve ERC20 abi
    with open(os.path.join(appDir, "../bin/contracts/ERC20.abi"), "r") as abiFile:
        abiERC20 = abiFile.read()
    
    token = w3.eth.contract(address=tokenAddress, abi=abiERC20)

    # approve the token transfer
    # estimatedGas = token.functions.approve(tradeBot.address, tokenAmount).estimateGas({
    #     "from": w3.eth.defaultAccount.address,
    # })
    gasPrice = w3.eth.generateGasPrice()
    tx = token.functions.approve(tradeBot.address, tokenAmount).buildTransaction({
        "from": w3.eth.defaultAccount.address,
        "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
        # "gas": estimatedGas,
        "gasPrice": gasPrice,
    })
    signAndSendTransaction(tx)

    # deposit the token
    # estimatedGas = tradeBot.functions.depositToken(tokenAddress, tokenAmount).estimateGas({
    #     "from": w3.eth.defaultAccount.address,
    # })
    gasPrice = w3.eth.generateGasPrice()
    tx = tradeBot.functions.depositToken(tokenAddress, tokenAmount).buildTransaction({
        "from": w3.eth.defaultAccount.address,
        "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
        # "gas": estimatedGas,
        "gasPrice": gasPrice,
    })
    signAndSendTransaction(tx)

def withdrawEth():
    # build the withdrawal transaction and send it
    # estimatedGas = tradeBot.functions.withdrawEth().estimateGas({
    #     "from": w3.eth.defaultAccount.address,
    # })
    gasPrice = w3.eth.generateGasPrice()
    tx = tradeBot.functions.withdrawEth().buildTransaction({
        "from": w3.eth.defaultAccount.address,
        "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
        # "gas": estimatedGas,
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

def getArbitrageProfitUSD(stableCoinAddress, mediatorCoinAddress, loanAmount, dexOrder):
    if dexOrder == "SELL_UNI_BUY_KYB":
        mediatorCoinAmount = getAmountOutUniswap(stableCoinAddress, mediatorCoinAddress, loanAmount)
        netTradeAmount = getAmountOutKyber(mediatorCoinAddress, stableCoinAddress, mediatorCoinAmount)
        
    if dexOrder == "SELL_KYB_BUY_UNI":
        mediatorCoinAmount = getAmountOutKyber(stableCoinAddress, mediatorCoinAddress, loanAmount)
        netTradeAmount = getAmountOutUniswap(mediatorCoinAddress, stableCoinAddress, mediatorCoinAmount)

    if (netTradeAmount > loanAmount * (FLASH_LOAN_FEE + 1)):
        return (netTradeAmount - loanAmount * (FLASH_LOAN_FEE + 1)) / DECIMALS_18
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

    # initialize API consumption
    session = getAPISession()

    # set which assets and amounts we want to trade with
    stableCoinAddress = ETH_MOCK_ADDRESS
    mediatorCoinAddress = DAI_ADDRESS
    loanAmount = 100000000000000000

    searchForArb = True
    while (searchForArb):
        # get gas price
        gasPrice = w3.eth.generateGasPrice()

        # get estimated gas
        estimatedGas = tradeBot.functions.arbExecute(stableCoinAddress, mediatorCoinAddress, loanAmount, "SELL_KYB_BUY_UNI").estimateGas({
        "from": w3.eth.defaultAccount.address,
        })

        # calculate the gas fee 
        gasFeeWei = estimatedGas * gasPrice
        gasFeeUSD = getGasFeeUSD(session, gasFeeWei)

        # for every dex order calculate potential profit and execute if greater than gas fee
        profit = getArbitrageProfitUSD(stableCoinAddress, mediatorCoinAddress, loanAmount, "SELL_KYB_BUY_UNI")
        if profit > gasFeeUSD:
            txReceipt = arbExecute(stableCoinAddress, mediatorCoinAddress, loanAmount, "SELL_KYB_BUY_UNI", estimatedGas, gasPrice)
            print("Trade made! Tx hash :" + str(txReceipt["transactionHash"]))
            searchForArb = False
        
        profit = getArbitrageProfitUSD(stableCoinAddress, mediatorCoinAddress, loanAmount, "SELL_UNI_BUY_KYB")
        # if profit > gasFeeUSD:
        txReceipt = arbExecute(stableCoinAddress, mediatorCoinAddress, loanAmount, "SELL_UNI_BUY_KYB", estimatedGas, gasPrice)
        print("Trade made! Tx hash :" + str(txReceipt["transactionHash"]))
        searchForArb = False
        
        time.sleep(10)


if __name__ == "__main__":
    main()
