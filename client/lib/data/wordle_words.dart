// lib/data/wordle_words.dart
//
// Hand-curated word list for Hops Wordle (lib/views/hops_wordle_page.dart) —
// common, family-friendly 5-letter English words, all lowercase. Kept as a
// plain Dart list rather than an asset file: a few hundred short strings is
// small enough that async asset loading would be pure overhead, and it's
// trivially bundled with the app the same way every other small constant
// table in this codebase is (see e.g. kCommunityDeleteReasonLabels).
//
// This is the ANSWER pool only — every entry here is a word that can be
// picked as the day's answer, but guesses are checked against the much
// larger dictionary in wordle_valid_guesses.dart instead (~14.8k words),
// same split a real Wordle uses ("fair answer" list vs. "accepted guess"
// list). Every word here is already confirmed to be a member of that
// larger set, so no possible answer is ever unguessable.
//
// wordleWordOfTheDay() in hops_wordle_page.dart picks a word deterministically
// from today's date AND the signed-in username, so two different users see
// two different words on the same day (no free-carrot answer-sharing) while
// a single user's own devices still agree with each other — do not reorder
// or remove entries without expecting everyone's word of the day to shift
// on the next build.
const List<String> kWordleWords = [
  'about', 'above', 'abuse', 'actor', 'acute', 'admit', 'adopt', 'adult', 'agent', 'agree',
  'ahead', 'alarm', 'album', 'alert', 'alike', 'alive', 'allow', 'alone', 'along', 'alter',
  'among', 'angel', 'anger', 'angle', 'angry', 'apart', 'apple', 'apply', 'arena', 'argue',
  'arise', 'armor', 'aside', 'asset', 'audio', 'audit', 'avoid', 'awake', 'award', 'aware',
  'badly', 'baker', 'basic', 'basis', 'beach', 'began', 'begin', 'being', 'below', 'bench',
  'birth', 'black', 'blame', 'blank', 'blast', 'blend', 'blind', 'block', 'blood', 'board',
  'boost', 'booth', 'bound', 'brain', 'brand', 'brave', 'bread', 'break', 'breed', 'brick',
  'brief', 'bring', 'broad', 'broke', 'brown', 'brush', 'build', 'built', 'burst', 'buyer',
  'cabin', 'cable', 'carry', 'catch', 'cause', 'chain', 'chair', 'chalk', 'charm', 'chart',
  'chase', 'cheap', 'check', 'chest', 'chief', 'child', 'chose', 'civil', 'claim', 'class',
  'clean', 'clear', 'click', 'cliff', 'climb', 'clock', 'close', 'cloud', 'coach', 'coast',
  'could', 'count', 'court', 'cover', 'craft', 'crash', 'crazy', 'cream', 'crime', 'cross',
  'crowd', 'crown', 'crude', 'curve', 'cycle', 'daily', 'dance', 'dealt', 'death', 'debut',
  'delay', 'depth', 'doubt', 'dozen', 'draft', 'drama', 'drank', 'drawn', 'dream', 'dress',
  'drift', 'drink', 'drive', 'drove', 'dying', 'eager', 'early', 'earth', 'eight', 'elite',
  'empty', 'enemy', 'enjoy', 'enter', 'entry', 'equal', 'error', 'event', 'every', 'exact',
  'exist', 'extra', 'faith', 'false', 'fault', 'favor', 'fence', 'fewer', 'fiber', 'field',
  'fifth', 'fifty', 'fight', 'final', 'first', 'fixed', 'flame', 'flash', 'fleet', 'flesh',
  'float', 'flock', 'floor', 'fluid', 'focus', 'force', 'forge', 'forth', 'forty', 'forum',
  'found', 'frame', 'fraud', 'fresh', 'front', 'frost', 'fruit', 'fully', 'funny', 'giant',
  'given', 'glass', 'globe', 'glory', 'going', 'grace', 'grade', 'grain', 'grand', 'grant',
  'grape', 'graph', 'grasp', 'grass', 'grave', 'great', 'green', 'greet', 'grief', 'grill',
  'gross', 'group', 'grown', 'guard', 'guess', 'guest', 'guide', 'habit', 'happy', 'harsh',
  'heart', 'heavy', 'hence', 'honor', 'horse', 'hotel', 'house', 'human', 'humor', 'hurry',
  'ideal', 'image', 'imply', 'index', 'inner', 'input', 'issue', 'ivory', 'joint', 'judge',
  'juice', 'knife', 'known', 'label', 'labor', 'large', 'laser', 'later', 'laugh', 'layer',
  'learn', 'least', 'leave', 'legal', 'level', 'light', 'limit', 'local', 'lodge', 'logic',
  'loose', 'lower', 'lucky', 'lunch', 'lying', 'magic', 'major', 'maker', 'march', 'match',
  'maybe', 'mayor', 'meant', 'media', 'metal', 'might', 'minor', 'minus', 'mixed', 'model',
  'moist', 'money', 'month', 'moral', 'motor', 'mount', 'mouse', 'mouth', 'moved', 'movie',
  'music', 'naked', 'nasty', 'naval', 'nerve', 'never', 'newly', 'night', 'noble', 'noise',
  'north', 'noted', 'novel', 'nurse', 'occur', 'ocean', 'offer', 'often', 'order', 'other',
  'ought', 'outer', 'owner', 'panel', 'paper', 'party', 'pause', 'peace', 'pearl', 'phase',
  'phone', 'photo', 'piece', 'pilot', 'pitch', 'place', 'plain', 'plane', 'plant', 'plate',
  'point', 'pound', 'power', 'press', 'price', 'pride', 'prime', 'print', 'prior', 'prize',
  'proof', 'proud', 'prove', 'queen', 'quick', 'quiet', 'quite', 'radio', 'raise', 'range',
  'rapid', 'ratio', 'reach', 'react', 'ready', 'realm', 'rebel', 'refer', 'relax', 'reply',
  'right', 'rigid', 'rival', 'river', 'roast', 'robot', 'rough', 'round', 'route', 'royal',
  'rural', 'salad', 'sauce', 'scale', 'scene', 'scope', 'score', 'sense', 'serve', 'seven',
  'shade', 'shake', 'shall', 'shape', 'share', 'shark', 'sharp', 'sheet', 'shelf', 'shell',
  'shift', 'shine', 'shirt', 'shock', 'shoot', 'short', 'shown', 'sight', 'silly', 'since',
  'sixth', 'sixty', 'sized', 'skill', 'sleep', 'slice', 'slide', 'small', 'smart', 'smell',
  'smile', 'smoke', 'snake', 'solid', 'solve', 'sorry', 'sound', 'south', 'space', 'spare',
  'speak', 'speed', 'spend', 'spent', 'spoke', 'sport', 'staff', 'stage', 'stake', 'stand',
  'start', 'state', 'steam', 'steel', 'steep', 'stick', 'still', 'stock', 'stone', 'store',
  'storm', 'story', 'strip', 'study', 'stuff', 'style', 'sugar', 'suite', 'super', 'sweet',
  'swept', 'swift', 'swing', 'sword', 'table', 'taken', 'taste', 'teach', 'thank', 'theme',
  'there', 'thick', 'thing', 'think', 'third', 'those', 'three', 'threw', 'throw', 'thumb',
  'tiger', 'tight', 'timer', 'title', 'today', 'token', 'topic', 'total', 'touch', 'tough',
  'tower', 'trace', 'track', 'trade', 'trail', 'train', 'trait', 'treat', 'trend', 'trial',
  'tribe', 'trick', 'tried', 'tries', 'truck', 'truly', 'trust', 'truth', 'twice', 'ultra',
  'uncle', 'under', 'union', 'unity', 'until', 'upper', 'upset', 'urban', 'usage', 'usual',
  'valid', 'value', 'video', 'virus', 'vital', 'vocal', 'voice', 'waste', 'watch', 'water',
  'weigh', 'weird', 'whale', 'wheat', 'wheel', 'where', 'which', 'while', 'white', 'whole',
  'whose', 'woman', 'world', 'worry', 'worse', 'worst', 'worth', 'would', 'wound', 'write',
  'wrong', 'yield', 'young', 'youth',
];
