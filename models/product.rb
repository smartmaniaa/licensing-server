# ---- models/product.rb (Versão 100% Completa com Correção de Coluna) ----

class Product
  def self.all
    $db.exec('SELECT * FROM products ORDER BY name')
  end

  def self.find(sku)
    result = $db.exec_params('SELECT * FROM products WHERE sku = $1', [sku])
    result.num_tuples > 0 ? result[0] : nil
  end

def self.create(sku:, name:, family:, latest_version:, download_link:)
  begin
    $db.exec_params(
      'INSERT INTO products (sku, name, family, latest_version, download_link) VALUES ($1, $2, $3, $4, $5)',
      [sku, name, family, latest_version, download_link]
    )
    return true
  rescue PG::UniqueViolation => e
    puts "[VALIDATION ERROR] Tentativa de criar produto com SKU ou Nome duplicado: #{e.message}"
    return false
  end
end

def self.update(sku:, name:, family:, latest_version:, download_link:)
  begin
    $db.exec_params(
      'UPDATE products SET name = $1, family = $2, latest_version = $3, download_link = $4 WHERE sku = $5',
      [name, family, latest_version, download_link, sku]
    )
    return true
  rescue PG::UniqueViolation => e
    puts "[VALIDATION ERROR] Tentativa de atualizar para um Nome que já existe: #{e.message}"
    return false
  end
end

  def self.delete(sku)
    $db.exec_params('DELETE FROM products WHERE sku = $1', [sku])
  end

  # --- Métodos para a "Ponte" com as Plataformas ---

  def self.find_platform_products_for_sku(sku)
    $db.exec_params('SELECT * FROM platform_products WHERE product_sku = $1', [sku])
  end

  def self.save_platform_product(sku:, platform:, platform_id:, link:)
    result = $db.exec_params(
      'UPDATE platform_products SET platform_id = $1, purchase_link = $2 WHERE product_sku = $3 AND platform = $4',
      [platform_id, link, sku, platform]
    )
    if result.cmd_tuples.zero?
      $db.exec_params(
        'INSERT INTO platform_products (product_sku, platform, platform_id, purchase_link) VALUES ($1, $2, $3, $4)',
        [sku, platform, platform_id, link]
      )
    end
  end
  
  # --- Métodos para Suites ---
  
  def self.find_suite_components(suite_sku)
    $db.exec_params('SELECT * FROM suite_components WHERE suite_product_id = $1', [suite_sku])
  end

  def self.update_suite_components(suite_sku:, component_skus:)
    $db.exec_params('DELETE FROM suite_components WHERE suite_product_id = $1', [suite_sku])
    
    component_skus.each do |comp_sku|
      # ==========================================================
      # CORREÇÃO APLICADA AQUI ('component_product_sku' -> 'component_product_id')
      # ==========================================================
      $db.exec_params(
        'INSERT INTO suite_components (suite_product_id, component_product_id) VALUES ($1, $2)',
        [suite_sku, comp_sku]
      )
    end
  end
end
