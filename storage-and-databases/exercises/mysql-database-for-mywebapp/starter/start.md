aws cloudformation create-stack --stack-name mysqlexercise --template-body file://network.yml --parameters file://params.json --region=us-east-1

aws cloudformation update-stack --stack-name mysqlexercise --template-body file://network.yml --parameters file://params.json --region=us-east-1