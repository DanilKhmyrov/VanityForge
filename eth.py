import asyncio

from web3 import AsyncWeb3


ERC20_ALT_COINS = {
    "ARB": {"address": "0xb50721bcf8d664c30412cfbc6cf7a15145234ad1", "decimals": 18},
    "USDT": {"address": "0xdac17f958d2ee523a2206206994597c13d831ec7", "decimals": 6},
    "USDC": {"address": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "decimals": 6},
    "USDS": {"address": "0xdc035d45d973e3ec169d2276ddab16f1e407384f", "decimals": 18},
    "AAVE": {"address": "0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9", "decimals": 18},
    "LINK": {"address": "0x514910771af9ca656af840dff83e8264ecf986ca", "decimals": 18},
}


class ETH:

    def __init__(self):
        self.rpc_url = "https://ethereum-rpc.publicnode.com"
        self.ERC20_ALT_COINS = ERC20_ALT_COINS

    async def __aenter__(self):
        self.client = AsyncWeb3(AsyncWeb3.AsyncHTTPProvider(self.rpc_url))
        if not await self.client.is_connected():
            raise ConnectionError("Cannot connect to ETH node")
        return self.client

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        for _, session in self.client.provider._request_session_manager.session_cache.items():
            await session.close()
        if hasattr(self.client.provider, '_http_session') and self.client.provider._http_session:
            await self.client.provider._http_session.close()
        self.client.provider._request_session_manager.session_cache.clear()
        return True

    async def get_all_balances(self, wallet_address):
        try:
            from eth_abi import encode
            from web3 import Web3

            async with ETH() as web3:

                checksum = web3.to_checksum_address(wallet_address)

                MULTICALL3_ABI = [
                    {
                        "inputs": [
                            {
                                "components": [
                                    {"name": "target", "type": "address"},
                                    {"name": "allowFailure", "type": "bool"},
                                    {"name": "callData", "type": "bytes"},
                                ],
                                "name": "calls",
                                "type": "tuple[]",
                            }
                        ],
                        "name": "aggregate3",
                        "outputs": [
                            {
                                "components": [
                                    {"name": "success", "type": "bool"},
                                    {"name": "returnData", "type": "bytes"},
                                ],
                                "type": "tuple[]",
                            }
                        ],
                        "stateMutability": "view",
                        "type": "function",
                    }
                ]

                multicall = web3.eth.contract(
                    address=web3.to_checksum_address(
                        "0xcA11bde05977b3631167028862bE2a173976CA11"
                    ),
                    abi=MULTICALL3_ABI
                )

                balance_sig = Web3.keccak(text="balanceOf(address)")[:4]

                tokens = list(self.ERC20_ALT_COINS.items())

                calls = [
                    {
                        "target": web3.to_checksum_address(info["address"]),
                        "allowFailure": True,
                        "callData": balance_sig + encode(["address"], [checksum])
                    }
                    for _, info in tokens
                ]

                eth_balance, results = await asyncio.gather(
                    web3.eth.get_balance(checksum),
                    multicall.functions.aggregate3(calls).call()
                )

                balances = {
                    "ETH": float(web3.from_wei(eth_balance, "ether"))
                }

                for (symbol, info), res in zip(tokens, results):
                    success = res[0]
                    data = res[1]

                    if not success or not data:
                        continue

                    try:
                        raw = int.from_bytes(data, "big")
                        bal = raw / (10 ** info["decimals"])

                        if bal > 0:
                            balances[symbol] = bal
                    except:
                        continue

                return balances

        except Exception as e:
            print("ETH get_all_balances error:", e)
            return {}
