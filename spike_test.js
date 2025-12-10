import http from 'k6/http';
import { sleep } from 'k6';

export let options = {
  stages: [
    { duration: '10s', target: 50 },
    { duration: '10s', target: 200 },
    { duration: '10s', target: 400 },
    { duration: '20s', target: 600 },
    { duration: '10s', target: 0 },
  ]
};

export default function () {
  http.get(__ENV.TARGET);
  sleep(0.1);
}
