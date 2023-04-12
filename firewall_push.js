var fs = require("fs");
var token = '';
var topic = '';
var tmp = fs.readFileSync("/root/firewall/firewall.log").toString();
//var Room = fs.readFileSync("/data/data/com.termux/files/home/push/Room").toString();
//var title = fs.readFileSync("/data/data/com.termux/files/home/push/status.txt").toString().replace(/[\r\n]/g, "");
//console.log(title)
console.log(tmp)
var request = require('request');
        const body = {
        token: '1e7fc6ac31e74054b851e7f9edd90235',
        title: '防火墙禁用',
        content: `${tmp}`,
        topic: `${topic}`
      };
        const options = {
                url: 'http://www.pushplus.plus/send',
                headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(body)
        };


request(options, function (error, resp,  data) {
  if (!error && resp.statusCode == 200) {
        console.log(error) // Print the shortened url.
        console.log(resp.statusCode)
        console.log(resp.body)
        //console.log(resp)
  }
});
