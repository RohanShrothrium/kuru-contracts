const express = require('express');

const app = express();

app.use('/lending', require('./lendingHandler'));
app.use('/factory', require('./factoryHandler'));
app.use('/smartWallet', require('./smartWalletHandler'));

module.exports = app;
