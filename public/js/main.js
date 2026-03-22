/**
 * main.js – Boot sequence
 * Collects fingerprint, starts behavior tracking, launches director loop.
 */

import { collectFingerprint } from './fingerprint.js';
import { createBehaviorTracker } from './behavior.js';
import { createDirector } from './director.js';

// Boot
const fingerprint = collectFingerprint();
const behavior = createBehaviorTracker();
behavior.start();

const director = createDirector(fingerprint, behavior);
director.start();
