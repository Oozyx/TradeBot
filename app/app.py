from eth_account import Account
from web3 import Web3, middleware
from web3.gas_strategies.time_based import fast_gas_price_strategy
import os

# initialize from our Infura provider
INFURA_ENDPOINT = "https://rinkeby.infura.io/v3/baf3c8ecbd384b4daef03573f23c0a30"
w3 = Web3(Web3.HTTPProvider(INFURA_ENDPOINT))
w3.middleware_onion.inject(middleware.geth_poa_middleware, layer=0) # necessary for Rinkeby only

# set gas price strategy
w3.eth.setGasPriceStrategy(fast_gas_price_strategy)

# define the directory of our app so we can use relative paths
appDir = os.path.abspath(os.path.dirname(__file__))

# declare an instance of our contract
tradeBot = None

# constants
DECIMALS_18 = 1000000000000000000

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

def depositEth(ethAmount):
    # make sure requested amount is available
    if ethAmount > w3.eth.getBalance(w3.eth.defaultAccount.address):
        raise ValueError("Attempted to deposit more ETH than what is currently in our wallet.")
    estimatedGas = tradeBot.functions.depositEth().estimateGas({
        "from": w3.eth.defaultAccount.address,
    })
    gasPrice = w3.eth.generateGasPrice()
    tx = tradeBot.functions.depositEth().buildTransaction({
        "value": ethAmount,
        "from": w3.eth.defaultAccount.address,
        "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
        "gas": estimatedGas,
        "gasPrice": gasPrice,
    })
    signAndSendTransaction(tx)

def depositToken(tokenAddress, tokenAmount):
    # retrieve ERC20 abi
    with open(os.path.join(appDir, "../bin/contracts/ERC20.abi"), "r") as abiFile:
        abiERC20 = abiFile.read()
    
    token = w3.eth.contract(address=tokenAddress, abi=abiERC20)

    # approve the token transfer
    estimatedGas = token.functions.approve(tradeBot.address, tokenAmount).estimateGas({
        "from": w3.eth.defaultAccount.address,
    })
    gasPrice = w3.eth.generateGasPrice()
    tx = token.functions.approve(tradeBot.address, tokenAmount).buildTransaction({
        "from": w3.eth.defaultAccount.address,
        "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
        "gas": estimatedGas,
        "gasPrice": gasPrice,
    })
    signAndSendTransaction(tx)

    # deposit the token
    estimatedGas = tradeBot.functions.depositToken(tokenAddress, tokenAmount).estimateGas({
        "from": w3.eth.defaultAccount.address,
    })
    gasPrice = w3.eth.generateGasPrice()
    tx = tradeBot.functions.depositToken(tokenAddress, tokenAmount).buildTransaction({
        "from": w3.eth.defaultAccount.address,
        "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
        "gas": estimatedGas,
        "gasPrice": gasPrice,
    })
    signAndSendTransaction(tx)

def withdrawEth():
    # build the withdrawal transaction and send it
    estimatedGas = tradeBot.functions.withdrawEth().estimateGas({
        "from": w3.eth.defaultAccount.address,
    })
    gasPrice = w3.eth.generateGasPrice()
    tx = tradeBot.functions.withdrawEth().buildTransaction({
        "from": w3.eth.defaultAccount.address,
        "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
        "gas": estimatedGas,
        "gasPrice": gasPrice,
    })
    signAndSendTransaction(tx)

def withdrawToken(tokenAddress):
    estimatedGas = tradeBot.functions.withdrawToken(tokenAddress).estimateGas({
        "from": w3.eth.defaultAccount.address,
    })
    gasPrice = w3.eth.generateGasPrice()
    tx = tradeBot.functions.withdrawToken(tokenAddress).buildTransaction({
        "from": w3.eth.defaultAccount.address,
        "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
        "gas": estimatedGas,
        "gasPrice": gasPrice,
    })
    signAndSendTransaction(tx)

def main():
    try:
        initializeContract()
    except ValueError as e:
        print(e)
        exit()

    withdrawEth()
    withdrawToken("0xDA5B056Cfb861282B4b59d29c9B395bcC238D29B")
    withdrawToken("0x6FA355a7b6bD2D6bD8b927C489221BFBb6f1D7B2")
    # depositEth(1 * DECIMALS_18)
    # depositToken("0xDA5B056Cfb861282B4b59d29c9B395bcC238D29B", 264 * DECIMALS_18)
    # depositToken("0x6FA355a7b6bD2D6bD8b927C489221BFBb6f1D7B2", 1000 * DECIMALS_18)

if __name__ == "__main__":
    main()

