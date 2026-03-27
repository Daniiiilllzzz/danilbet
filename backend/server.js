import express from 'express';
import cors from 'cors';
import mongoose from 'mongoose';
import dotenv from 'dotenv';
import jwt from 'jsonwebtoken';

dotenv.config();

const app = express();
app.use(express.json());
app.use(cors());

mongoose.connect(process.env.MONGO_URI ?? '', {
  autoIndex: true,
});

const SECRET = process.env.JWT_SECRET ?? 'CHANGE_ME_IN_PRODUCTION';

const userSchema = new mongoose.Schema({
  username: { type: String, unique: true },
  password: String, // TODO: hash with bcrypt before production
  balance: { type: Number, default: 1000 },
});

const betSchema = new mongoose.Schema({
  userId: mongoose.Schema.Types.ObjectId,
  stake: Number,
  odd: Number,
  gain: Number,
  date: { type: Date, default: Date.now },
});

const User = mongoose.model('User', userSchema);
const Bet = mongoose.model('Bet', betSchema);

function parseToken(authHeader) {
  if (!authHeader) return null;
  const parts = authHeader.split(' ');
  if (parts.length === 2 && parts[0] === 'Bearer') return parts[1];
  return authHeader;
}

function auth(req, res, next) {
  try {
    const token = parseToken(req.headers.authorization);
    if (!token) return res.status(401).send('Missing token');

    const decoded = jwt.verify(token, SECRET);
    req.userId = decoded.id;
    next();
  } catch {
    return res.status(401).send('Invalid token');
  }
}

app.post('/register', async (req, res) => {
  const { username, password } = req.body;
  if (!username || !password) return res.status(400).send('Missing fields');

  const exists = await User.findOne({ username });
  if (exists) return res.status(409).send('User exists');

  const user = await User.create({ username, password });
  const token = jwt.sign({ id: user._id }, SECRET, { expiresIn: '7d' });
  res.send({ token });
});

app.post('/login', async (req, res) => {
  const { username, password } = req.body;
  const user = await User.findOne({ username });
  if (!user || user.password !== password) return res.status(401).send('Invalid credentials');

  const token = jwt.sign({ id: user._id }, SECRET, { expiresIn: '7d' });
  res.send({ token });
});

app.get('/me', auth, async (req, res) => {
  const user = await User.findById(req.userId);
  res.send({ username: user.username, balance: user.balance });
});

app.post('/bet', auth, async (req, res) => {
  const { stake, odd } = req.body;
  const user = await User.findById(req.userId);

  if (typeof stake !== 'number' || stake <= 0) return res.status(400).send('Invalid stake');
  if (typeof odd !== 'number' || odd <= 1) return res.status(400).send('Invalid odd');
  if (stake > user.balance) return res.status(400).send('Not enough balance');

  user.balance -= stake;

  const win = Math.random() > 0.5;
  let gain = 0;

  if (win) {
    gain = stake * odd;
    user.balance += gain;
  }

  await user.save();
  await Bet.create({ userId: user._id, stake, odd, gain });

  res.send({ balance: user.balance, gain });
});

app.get('/history', auth, async (req, res) => {
  const bets = await Bet.find({ userId: req.userId }).sort({ date: -1 }).limit(200);
  res.send(bets);
});

const port = process.env.PORT ?? 3000;
app.listen(port, () => {
  console.log(`API running on :${port}`);
});
