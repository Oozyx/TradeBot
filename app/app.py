from eth_account import Account
from web3 import Web3, middleware

# initialize from our Infura provider
INFURA_ENDPOINT = "https://rinkeby.infura.io/v3/baf3c8ecbd384b4daef03573f23c0a30"
w3 = Web3(Web3.HTTPProvider(INFURA_ENDPOINT))
w3.middleware_onion.inject(middleware.geth_poa_middleware, layer=0) # necessary for Rinkeby only


# import our account
with open("C:\\Users\\Hendrik Oosenbrug\\Documents\\Dev\\ethereum-dev\\TradeBot\\app\\.privatekey", "r") as keyFile:
    myPrivateKey = keyFile.read()
    w3Account = Account()
    metaMaskAccount = w3Account.from_key(myPrivateKey)
    myAddress = metaMaskAccount.address
    print(myAddress)
    
# initialize contract instance
with open("C:\\Users\\Hendrik Oosenbrug\\Documents\\Dev\\ethereum-dev\\TradeBot\\bin\\contracts\\TradeBot.abi", "r") as abiFile:
    abiTradeBot = abiFile.read()
CONTRACT_ADDRESS = "0xeBF9b0c20267f9e447E190994e81BFD6b0fBd88D" # INSERT CONTRACT ADDRESS HERE
contract = w3.eth.contract(address=CONTRACT_ADDRESS, abi=abiTradeBot)

result = 0
result = contract.functions.getMinConversionRateKyber().call()
print(result)

# # build the transaction
# transaction = contract.functions.getMinConversionRateKyber(  
#     ).buildTransaction({
#         "nonce": w3.eth.getTransactionCount(myAddress),
#         "gas": 3000000,
# })

# # sign the transaction
# signedTransaction = w3.eth.account.sign_transaction(transaction, myPrivateKey)

# # send the transaction
# w3.eth.sendRawTransaction(signedTransaction.rawTransaction)

