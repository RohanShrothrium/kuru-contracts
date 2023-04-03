const express = require('express');
const config = require('../../config.json');
const smartWallet = require("../services/smartWalletService");

const app = express();

// req.param isLong: bool
app.get('/getPosition/:isLong', (req, res) => {
  const { isLong } = req.params;

  smartWallet.GetPosition(config.wethAddress, isLong == "true").then(
      result => res.status(200).json(result),
  );
});

app.get('/getPositions', (req, res) => {
    smartWallet.GetPositions().then(
        result => res.status(200).json(result),
    );
  });

// no params
app.get('/getPortfolioValue', (req, res) => {
  smartWallet.GetPortfolioValue().then(
      result => res.status(200).json(result),
  );
});

// no params
app.get('/getPortfolioValueWithMargin', (req, res) => {
    smartWallet.GetPortfolioValueWithMargin().then(
        result => res.status(200).json(result),
    );
  });

// no params
app.get('/getHealthFactor', (req, res) => {
    smartWallet.GetHealthFactor().then(
        result => res.status(200).json(result),
    );
  });

// req.body {collateral: string, leverage: number, ethAcceptablePrice: string, isLong: bool}
app.post('/createIncreasePosition', (req, res) => {
    const {collateral, leverage, ethAcceptablePrice, isLong} = req.body;

    smartWallet.CreateIncreasePosition(collateral, leverage, ethAcceptablePrice, isLong).then(
      result => res.status(200).json(result),
    );
});

// req.body {collateralDelta: string, sizeDelta: string, ethAcceptablePrice: string, isLong: bool}
app.post('/createDecreasePosition', (req, res) => {
    const {collateralDelta, sizeDelta, ethAcceptablePrice, isLong} = req.body;

    smartWallet.CreateDecreasePosition(collateralDelta, sizeDelta, ethAcceptablePrice, isLong).then(
      result => res.status(200).json(result),
    );
});

module.exports = app;
