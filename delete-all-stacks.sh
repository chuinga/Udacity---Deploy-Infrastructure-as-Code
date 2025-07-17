#!/bin/bash

echo "🔍 A identificar stacks ativos..."

# Obter todos os stacks que não estão terminados
stacks=$(aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query "StackSummaries[*].StackName" --output text)

if [ -z "$stacks" ]; then
  echo "✅ Nenhum stack ativo encontrado."
  exit 0
fi

echo "🚨 Vão ser apagados os seguintes stacks:"
for stack in $stacks; do
  echo "🗑️  $stack"
done

read -p "❓ Confirmas que queres apagar todos estes stacks? (y/N): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "❌ Operação cancelada."
  exit 1
fi

# Apagar cada stack
for stack in $stacks; do
  echo "⏳ A apagar stack: $stack ..."
  aws cloudformation delete-stack --stack-name "$stack"
done

echo "⌛ A aguardar remoção completa..."
for stack in $stacks; do
  aws cloudformation wait stack-delete-complete --stack-name "$stack"
  echo "✅ Stack $stack removido."
done

echo "🏁 Todos os stacks foram apagados com sucesso."
