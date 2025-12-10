import http from 'k6/http';
import { check } from 'k6';

export let options = {
  vus: 800,           // 50 usuarios virtuales concurrentes
  iterations: 10000  // total de requests = 10.000
};

export default function () {
  let res = http.get(__ENV.TARGET || "http://TU_ALB_DNS");
  check(res, { "status 200": (r) => r.status === 200 });
}
