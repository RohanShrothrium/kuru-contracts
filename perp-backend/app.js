const express = require('express');
const helmet = require('helmet');
const multer = require('multer');
const cors = require('cors');
const handlers = require('./handlers/handler');

const app = express();
const port = 8080;
const upload = multer();
// for parsing application/json
app.use(express.json());
app.use(helmet());
app.use(cors({
    origin: true,
    credentials: true,
}));

// for parsing multipart/form-data
app.use(upload.array());

// for parsing application/x-www-form-urlencoded
app.use(
    express.urlencoded({
        extended: true,
    }),
);

app.use('/api', handlers);

app.listen(port, () => {
    console.log(`Example app listening on port ${port}`)
})

module.exports = app;
