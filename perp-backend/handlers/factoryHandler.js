const express = require('express');
const factoryService = require("../services/factoryService");

const app = express();

// no body or params
app.post('/createSmartWallet', (req, res) => {
    factoryService.CreateSmartWallet().then(
      result => res.status(200).json(result),
    );
});

module.exports = app;
