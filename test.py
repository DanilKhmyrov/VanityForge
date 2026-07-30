
import asyncio

from eth import ETH


async def test():
    a = await ETH().get_all_balances("0x18ed7bfaaaaaaaaaae8f59ff7ccd94e93c10ca6e")
    print(a)


asyncio.run(test())