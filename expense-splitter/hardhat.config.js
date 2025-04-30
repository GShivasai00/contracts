require("@nomicfoundation/hardhat-toolbox");
require('dotenv').config();

    module.exports = {
         networks: {
              goerli: {
                    url: `https://goerli.infura.io/v3/${process.env.INFURA_API_KEY}`,
                    accounts: [`0x${process.env.PRIVATE_KEY}`]
              }
         },
         solidity: "0.8.4",
    };