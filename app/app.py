from eth_account import Account
from web3 import Web3, middleware
import os

# initialize from our Infura provider
INFURA_ENDPOINT = "https://rinkeby.infura.io/v3/baf3c8ecbd384b4daef03573f23c0a30"
w3 = Web3(Web3.HTTPProvider(INFURA_ENDPOINT))
w3.middleware_onion.inject(middleware.geth_poa_middleware, layer=0) # necessary for Rinkeby only

# declare an instance of our contract
tradeBot = None

def initializeContract():
    appDir = os.path.abspath(os.path.dirname(__file__))

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
            raise ValueError("Latest contract build does not matched latest deployed.")

        tradeBot = w3.eth.contract(address=addressSaved, abi=abiSaved)
    else:
        # retrieve abi and bytecode
        with open(os.path.join(appDir, "../bin/contracts/TradeBot.abi"), "r") as abiFile:
            abiTradeBot = abiFile.read()

        with open(os.path.join(appDir, "../bin/contracts/TradeBot.bin"), "r") as byteFile:
            byteTradeBot = byteFile.read()

        # deploy the contract
        TradeBot = w3.eth.contract(abi=abiTradeBot, bytecode=byteTradeBot)
        tx = TradeBot.constructor().buildTransaction({
            "from": w3.eth.defaultAccount.address,
            "nonce": w3.eth.getTransactionCount(w3.eth.defaultAccount.address),
        })
        txSigned = w3.eth.account.sign_transaction(tx, w3.eth.defaultAccount.privateKey)
        txHash = w3.eth.sendRawTransaction(txSigned.rawTransaction)
        txReceipt = w3.eth.waitForTransactionReceipt(txHash)
        
        # retrieve an instance of the contract
        tradeBot = w3.eth.contract(address=txReceipt.contractAddress, abi=abiTradeBot)
        result = tradeBot.functions.getMinConversionRateKyber().call({
            "from": w3.eth.defaultAccount.address,
        })
        print(result)
        
        # write to file so we don't redeploy if not necessary
        with open(os.path.join(appDir, ".contractinfo"), "w") as contractInfo:
            contractInfo.write(abiTradeBot + "\n")
            contractInfo.write(tradeBot.address + "\n")

def main():
    try:
        initializeContract()
    except ValueError as e:
        print(e)
        print("Rebuild contract and delete saved contract info file.")
        exit()

    result = tradeBot.functions.getMinConversionRateKyber().call({
            "from": w3.eth.defaultAccount.address,
        })
    print(result)

if __name__ == "__main__":
    main()

