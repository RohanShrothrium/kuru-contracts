const express = require('express');
const lendingService = require("../services/lendingService");

const app = express();

// no params or body
app.get('/getReserve', (req, res) => {
    lendingService.GetReserve().then(
        result => res.status(200).json(result),
    );
});

// no params or body
app.get('/getUserUsdc', (req, res) => {
    lendingService.GetUSDCBalance().then(
        result => res.status(200).json(result),
    );
});

// no params or body
app.get('/existingLoan', (req, res) => {
    lendingService.GetExistingLoan().then(
        result => res.status(200).json(result),
    );
});

// req.params {isLong: bool}
app.get('/getAcceptablePrice/:isLong', (req, res) => {
    const { isLong } = req.params;
    lendingService.GetEthAcceptablePrice(isLong == "true").then(
        result => res.status(200).json(result),
    );
});

// req.body {amount: string}
app.post('/provideLiquidity', (req, res) => {
    const { amount } = req.body;

    lendingService.ProvideLiquidity(amount).then(
        result => res.status(200).json(result),
    );
});

// req.body {loanAmount: string, isLong: bool}
app.post('/takeLoan', (req, res) => {
    const { loanAmount } = req.body;

    lendingService.TakeLoanOnEthPosition(loanAmount).then(
        result => res.status(200).json(result),
    );
});

// req.body {loanAmount: string, isLong: bool}
app.post('/paybackLoan', (req, res) => {
    const { loanAmount } = req.body;

    lendingService.PaybackLoanOnEthPosition(loanAmount).then(
        result => res.status(200).json(result),
    );
});

module.exports = app;
